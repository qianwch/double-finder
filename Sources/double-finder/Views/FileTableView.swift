import AppKit
import UniformTypeIdentifiers
import QuickLookThumbnailing

protocol FileTableViewDelegate: AnyObject {
    func fileTableView(_ tableView: FileTableView, didDoubleClickItem item: FileItem)
    func fileTableView(_ tableView: FileTableView, didPressEnterOnItem item: FileItem)
    func fileTableViewDidChangeCursor(_ tableView: FileTableView, to index: Int)
    func fileTableView(_ tableView: FileTableView, didClickRow row: Int, extend: Bool, toggle: Bool)
    func fileTableViewWantsActivation(_ tableView: FileTableView)
    func fileTableView(_ tableView: FileTableView, didPressSpaceOnIndex index: Int)
    func fileTableView(_ tableView: FileTableView, didClickColumn identifier: String)
    func fileTableView(_ tableView: FileTableView, didToggleExpand item: FileItem)
    func fileTableView(_ tableView: FileTableView, didRename item: FileItem, to newName: String)
    func fileTableView(_ tableView: FileTableView, didDropFiles urls: [URL], move: Bool)
}

class FileTableView: NSScrollView {
    let tableView: NCTableView
    weak var fileDelegate: FileTableViewDelegate?

    var items: [FileItem] = [] {
        didSet {
            iconCache.removeAll(keepingCapacity: true)   // icons are path-keyed; drop on dir change
            tableView.reloadData()
        }
    }

    var selectedItems: Set<UUID> = [] {
        didSet { tableView.reloadData() }
    }

    var cursorIndex: Int = 0 {
        didSet {
            // Only repaint the highlight; scrolling is decided by the controller
            // (keep position on refresh/navigation, follow cursor on key moves).
            if cursorIndex != oldValue {
                tableView.reloadData()
            }
        }
    }

    var isActivePanel: Bool = false {
        didSet { tableView.reloadData() }
    }

    /// Paths of folders currently expanded in place (drives the disclosure
    /// triangle state in the name cell).
    var expandedPaths: Set<String> = []

    var viewMode: FileViewMode = .full {
        didSet { if viewMode != oldValue { applyViewMode() } }
    }

    /// QuickLook thumbnail cache, keyed by file path (thumbnails mode only).
    private var thumbnailCache: [String: NSImage] = [:]
    private var thumbnailsRequested: Set<String> = []

    /// Rendered file-icon cache, keyed by "path|side". `icon(forFile:)` + the
    /// offscreen fixed-size redraw cost ~0.5 ms each; since cursor/selection
    /// moves trigger a full `reloadData()`, every visible row would otherwise
    /// re-render its icon on every keypress (fine on Apple Silicon, janky on
    /// older Intel). Cleared whenever `items` changes (new directory).
    private var iconCache: [String: NSImage] = [:]

    private var nameColumn: NSTableColumn!
    private var sizeColumn: NSTableColumn!
    private var dateColumn: NSTableColumn!
    private var iconColumn: NSTableColumn!

    /// Optional columns (beyond Name) the user can show/hide via the header menu.
    /// Tuple: column id, header title, default width.
    static let optionalColumns: [(id: String, title: String, width: CGFloat)] = [
        ("size", "Size", 80), ("date", "Modified", 130),
        ("added", "Date Added", 130), ("created", "Date Created", 130),
        ("kind", "Kind", 130), ("perms", "Permissions", 100),
    ]

    init() {
        tableView = NCTableView()
        super.init(frame: .zero)

        documentView = tableView
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder

        setupTableView()
        viewMode = AppSettings.viewMode
        applyViewMode()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupTableView() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 28
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnSelection = false
        tableView.allowsEmptySelection = true
        tableView.intercellSpacing = NSSize(width: 3, height: 0)
        tableView.headerView = NSTableHeaderView()
        tableView.fileTableView = self
        // Accept file drops from Finder / other apps / the other panel.
        tableView.registerForDraggedTypes([.fileURL])

        // Name column (also hosts the disclosure triangle + icon, so the triangle
        // sits before the icon and the whole group indents together — Finder-style).
        nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = tr("Name")
        nameColumn.width = 330
        nameColumn.minWidth = 120
        nameColumn.isEditable = false
        tableView.addTableColumn(nameColumn)

        // Optional columns (Size / Modified / Date Added / Date Created / Kind /
        // Permissions). Visibility is driven by AppSettings + the header menu.
        let visible = Set(AppSettings.visibleColumns)
        for spec in Self.optionalColumns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            col.title = tr(spec.title)
            col.width = spec.width
            col.minWidth = 50
            col.isEditable = false
            col.isHidden = !visible.contains(spec.id)
            tableView.addTableColumn(col)
            if spec.id == "size" { sizeColumn = col }
            if spec.id == "date" { dateColumn = col }
        }

        // Right-click the header to choose which columns are shown.
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        tableView.headerView?.menu = headerMenu
    }

    /// Renders any icon into a fresh, fixed-size image so all rows render at the
    /// same pixel size regardless of the source icon's representation set.
    /// Applies the current view mode: which columns show, icon-column width,
    /// and triggers a reload + row-height recompute.
    /// Re-applies the current view mode (icon size / row height / columns) and
    /// redraws — call after changing the icon-size setting.
    func reloadLayout() { applyViewMode() }

    private func applyViewMode() {
        applyColumnVisibility()
        if viewMode != .thumbnails { thumbnailCache.removeAll(); thumbnailsRequested.removeAll() }
        tableView.reloadData()
        if !items.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
        }
    }

    /// Shows the optional columns selected in AppSettings — but only in Full view
    /// (Brief/Thumbnails show just the name).
    func applyColumnVisibility() {
        let visible = Set(AppSettings.visibleColumns)
        for spec in Self.optionalColumns {
            let col = tableView.tableColumns.first { $0.identifier.rawValue == spec.id }
            col?.isHidden = (viewMode != .full) || !visible.contains(spec.id)
        }
    }

    /// The icon image for an item at the given side length: the parent up-arrow,
    /// a cached QuickLook thumbnail (thumbnails mode), or the workspace file icon.
    private func iconImage(for item: FileItem, side: CGFloat) -> NSImage? {
        if item.name == ".." {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            return NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Parent")?
                .withSymbolConfiguration(cfg)
        }
        if viewMode == .thumbnails, let thumb = thumbnailCache[item.path] {
            return Self.fixedSizeIcon(thumb, side: side)
        }
        let key = "\(item.path)|\(Int(side))"
        if let cached = iconCache[key] { return cached }
        let rawIcon: NSImage
        if FileManager.default.fileExists(atPath: item.path) {
            rawIcon = NSWorkspace.shared.icon(forFile: item.path)
        } else if item.isDirectory {
            rawIcon = NSWorkspace.shared.icon(for: .folder)
        } else {
            let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data
            rawIcon = NSWorkspace.shared.icon(for: type)
        }
        let img = Self.fixedSizeIcon(rawIcon, side: side)
        iconCache[key] = img
        return img
    }

    /// Lazily generates a QuickLook thumbnail for a file and reloads its row.
    private func requestThumbnail(for item: FileItem, row: Int) {
        guard viewMode == .thumbnails, !item.isDirectory, item.name != "..",
              FileManager.default.fileExists(atPath: item.path),
              !thumbnailsRequested.contains(item.path) else { return }
        thumbnailsRequested.insert(item.path)
        let url = URL(fileURLWithPath: item.path)
        let scale = window?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 44, height: 44),
                                               scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let rep = rep else { return }
            let img = rep.nsImage
            DispatchQueue.main.async {
                guard let self = self, self.viewMode == .thumbnails else { return }
                self.thumbnailCache[item.path] = img
                if row < self.items.count, self.items[row].path == item.path {
                    self.tableView.reloadData(forRowIndexes: [row],
                                              columnIndexes: IndexSet(integer: 0))  // name column (icon lives here now)
                }
            }
        }
    }

    static func fixedSizeIcon(_ source: NSImage, side: CGFloat) -> NSImage {
        let size = NSSize(width: side, height: side)
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: size),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
        img.unlockFocus()
        return img
    }

    /// Scrolls just enough to keep `row` visible (for keyboard cursor moves).
    func ensureRowVisible(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        tableView.scrollRowToVisible(row)
    }

    /// Starts an inline rename of the name cell at `row`.
    func beginRename(row: Int) {
        guard row >= 0, row < items.count, items[row].name != ".." else { return }
        ensureRowVisible(row)
        let nameCol = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("name"))
        guard nameCol >= 0,
              let cell = tableView.view(atColumn: nameCol, row: row, makeIfNecessary: true) as? FileCellView
        else { return }
        let item = items[row]
        cell.onCommitRename = { [weak self] newName in
            guard let self = self else { return }
            self.fileDelegate?.fileTableView(self, didRename: item, to: newName)
        }
        cell.onEndRename = { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self.tableView)
        }
        cell.onFunctionKey = { [weak self] event in
            // After the rename tears down, restore table focus and run the key's
            // action directly via the main controller (F5 copy, F6 move, …).
            DispatchQueue.main.async {
                guard let self = self, let window = self.window else { return }
                window.makeFirstResponder(self.tableView)
                _ = (window.contentViewController as? MainViewController)?.handleKeyDown(event)
            }
        }
        cell.beginRename(currentName: item.name)
    }

    /// Index of the first row visible at the top of the viewport.
    var topVisibleRow: Int {
        let y = contentView.bounds.origin.y
        let r = tableView.row(at: NSPoint(x: 2, y: y + 1))
        return r >= 0 ? r : 0
    }

    /// Scrolls so `row` sits at the top of the viewport, using only NSTableView's
    /// own scrollRowToVisible (which lays out as needed) — robust against the
    /// lazy post-reloadData frame sizing that breaks manual clip-view scrolling.
    func scrollRowToTop(_ row: Int) {
        let count = items.count
        guard count > 0 else { return }
        let target = max(0, min(row, count - 1))
        if target == 0 {
            tableView.scrollRowToVisible(0)
            return
        }
        // Approach the target from below so it lands at the top of the viewport.
        tableView.scrollRowToVisible(count - 1)
        tableView.scrollRowToVisible(target)
    }

    /// Reflects the current sort in the column headers (arrow indicator).
    func updateSortIndicator(column identifier: String, ascending: Bool) {
        for col in tableView.tableColumns {
            tableView.setIndicatorImage(nil, in: col)
            if col.identifier.rawValue == identifier {
                let name = ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"
                tableView.setIndicatorImage(NSImage(named: name), in: col)
            }
        }
    }

    func jumpToLetter(_ char: Character) {
        let lower = char.lowercased().first ?? char
        for (i, item) in items.enumerated() {
            if item.name != ".." && item.name.lowercased().first == lower {
                cursorIndex = i
                fileDelegate?.fileTableViewDidChangeCursor(self, to: i)
                return
            }
        }
    }

    /// Re-applies the active language to column header titles.
    /// Called from PanelViewController.relocalize() on a live language switch.
    func relocalize() {
        // Name column is always present.
        if let col = tableView.tableColumns.first(where: { $0.identifier.rawValue == "name" }) {
            col.title = tr("Name")
        }
        // Optional columns: match by identifier and re-apply the translated title.
        for spec in Self.optionalColumns {
            if let col = tableView.tableColumns.first(where: { $0.identifier.rawValue == spec.id }) {
                col.title = tr(spec.title)
            }
        }
    }
}

// NCTableView: custom NSTableView to intercept key events
class NCTableView: NSTableView {
    weak var fileTableView: FileTableView?

    /// Local file URLs the context menu's Services submenu should act on. Set by
    /// the menu builder just before the menu shows; vended via NSServicesMenuRequestor.
    var serviceURLs: [URL] = []

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Pass to the window's key handler - don't handle here
        nextResponder?.keyDown(with: event)
    }

    private var renameWorkItem: DispatchWorkItem?

    override func mouseDown(with event: NSEvent) {
        renameWorkItem?.cancel(); renameWorkItem = nil
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard let ftv = fileTableView else {
            super.mouseDown(with: event)
            return
        }

        // Clicking the empty area below the rows still activates this panel.
        guard row >= 0, row < ftv.items.count else {
            ftv.fileDelegate?.fileTableViewWantsActivation(ftv)
            return
        }
        // A plain click on a row that's already the (single) selection enters
        // inline rename after the double-click interval — Finder-style. Captured
        // before reporting the click, since that updates the cursor.
        let wasCurrent = row == ftv.cursorIndex && ftv.selectedItems.count <= 1
        let mods = event.modifierFlags
        let noChord = mods.intersection([.command, .shift, .control, .option]).isEmpty
        // Selection logic lives in PanelState (shared with keyboard); just report
        // the row plus modifiers.
        ftv.fileDelegate?.fileTableView(ftv, didClickRow: row,
                                        extend: mods.contains(.shift),
                                        toggle: mods.contains(.command))

        if event.clickCount == 2 {
            ftv.fileDelegate?.fileTableView(ftv, didDoubleClickItem: ftv.items[row])
            return
        }

        // Track the mouse: a drag past the threshold starts a file drag, a plain
        // release (no drag) may begin an inline rename. Using nextEvent here (the
        // standard NSTableView idiom) is what makes mouse-drag actually fire.
        let draggable = ftv.items[row].name != ".." &&
            FileManager.default.fileExists(atPath: ftv.items[row].path)
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                if wasCurrent, noChord, ftv.items[row].name != ".." {
                    let wi = DispatchWorkItem { [weak ftv] in ftv?.beginRename(row: row) }
                    renameWorkItem = wi
                    DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: wi)
                }
                return
            }
            if draggable {
                let d = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
                if d > 4 { startFileDrag(originRow: row, event: next, ftv: ftv); return }
            }
        }
    }

    // MARK: - Drag source (drag files out to Finder / other apps / the other panel)

    private func startFileDrag(originRow: Int, event: NSEvent, ftv: FileTableView) {
        renameWorkItem?.cancel(); renameWorkItem = nil
        // Drag the whole selection if the origin row is part of it, else just it.
        let origin = ftv.items[originRow]
        let toDrag = ftv.selectedItems.contains(origin.id)
            ? ftv.items.filter { ftv.selectedItems.contains($0.id) && $0.name != ".." }
            : [origin]
        let valid = toDrag.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else { return }   // SFTP/archive entries have no real file URL

        var dragItems: [NSDraggingItem] = []
        for item in valid {
            let di = NSDraggingItem(pasteboardWriter: NSURL(fileURLWithPath: item.path))
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            icon.size = NSSize(width: 28, height: 28)
            if let rowIdx = ftv.items.firstIndex(where: { $0.id == item.id }) {
                var frame = rect(ofRow: rowIdx)
                frame.size = NSSize(width: 28, height: 28)
                di.setDraggingFrame(frame, contents: icon)
            }
            dragItems.append(di)
        }
        beginDraggingSession(with: dragItems, event: event, source: self)
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? [.copy, .move] : .copy
    }

    // MARK: - Drop destination (files dropped from Finder / other apps / the other panel)

    private func canAcceptDrop(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }
    private func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop(sender) else { return [] }
        let mask = sender.draggingSourceOperationMask
        // Cmd forces move within the app; default is copy.
        if NSEvent.modifierFlags.contains(.command), mask.contains(.move) { return .move }
        return mask.contains(.copy) ? .copy : (mask.contains(.move) ? .move : .copy)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let ftv = fileTableView,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let move = dropOperation(for: sender) == .move
        ftv.fileDelegate?.fileTableView(ftv, didDropFiles: urls, move: move)
        return true
    }
}

// MARK: - Header column-chooser menu
extension FileTableView: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = Set(AppSettings.visibleColumns)
        for spec in Self.optionalColumns {
            let item = NSMenuItem(title: tr(spec.title), action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec.id
            item.state = visible.contains(spec.id) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var cols = AppSettings.visibleColumns
        if let idx = cols.firstIndex(of: id) { cols.remove(at: idx) } else { cols.append(id) }
        AppSettings.visibleColumns = cols
        applyColumnVisibility()
    }
}

// MARK: - NSTableViewDataSource
extension FileTableView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return items.count
    }
}

// MARK: - NSTableViewDelegate
extension FileTableView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count else { return nil }
        let item = items[row]
        let isCursor = row == cursorIndex
        let isSelected = selectedItems.contains(item.id)

        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("name")

        switch identifier.rawValue {
        case "name":
            let cellId = NSUserInterfaceItemIdentifier("nameCell")
            var cell = tableView.makeView(withIdentifier: cellId, owner: nil) as? FileCellView
            if cell == nil {
                cell = FileCellView(identifier: cellId)
            }
            let expandable = item.isDirectory && item.name != ".."
            // Full/Brief use the configurable icon size (row height tracks it so
            // icons never clip); thumbnails keep their large preview size.
            let side: CGFloat = viewMode == .thumbnails ? 44 : CGFloat(AppSettings.iconSize)
            cell?.configure(
                text: item.name,
                isDirectory: item.isDirectory,
                isHidden: item.isHidden,
                isSymlink: item.isSymlink,
                isCursor: isCursor,
                isSelected: isSelected,
                isActive: isActivePanel,
                depth: item.depth,
                isExpandable: expandable,
                isExpanded: expandedPaths.contains(item.path),
                icon: iconImage(for: item, side: side),
                iconSide: side,
                iconTint: item.name == ".." ? .secondaryLabelColor : nil
            )
            if item.name != ".." { requestThumbnail(for: item, row: row) }
            cell?.onToggleExpand = { [weak self] in
                guard let self = self else { return }
                self.fileDelegate?.fileTableView(self, didToggleExpand: item)
            }
            return cell

        case "size":
            let cellId = NSUserInterfaceItemIdentifier("sizeCell")
            let cell = (tableView.makeView(withIdentifier: cellId, owner: nil) as? MetaCellView)
                ?? MetaCellView(identifier: cellId, alignment: .right)
            cell.label.stringValue = item.name == ".." ? "" : item.formattedSize
            cell.alphaValue = item.isHidden ? 0.5 : 1.0
            return cell

        case "date", "added", "created", "kind", "perms":
            let cellId = NSUserInterfaceItemIdentifier("metaCell_\(identifier.rawValue)")
            let cell = (tableView.makeView(withIdentifier: cellId, owner: nil) as? MetaCellView)
                ?? MetaCellView(identifier: cellId, alignment: .left)
            cell.label.stringValue = metaText(for: item, column: identifier.rawValue)
            cell.alphaValue = item.isHidden ? 0.5 : 1.0
            return cell

        default:
            return nil
        }
    }

    /// Text for an optional metadata column.
    private func metaText(for item: FileItem, column: String) -> String {
        if item.name == ".." { return "" }
        switch column {
        case "date": return item.formattedDate
        case "added": return item.formatted(item.dateAdded)
        case "created": return item.formatted(item.dateCreated)
        case "kind": return item.kind
        case "perms": return item.permissions.isEmpty ? LocalFS.permissions(for: item.path) : item.permissions
        default: return ""
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NCRowView()
        if row < items.count {
            let item = items[row]
            rowView.isCursorRow = row == cursorIndex
            rowView.isSelectedItem = selectedItems.contains(item.id)
            rowView.isPanelActive = isActivePanel
            rowView.isOddRow = row % 2 == 1
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let icon = CGFloat(AppSettings.iconSize)
        switch viewMode {
        case .full: return icon + 4
        case .brief: return icon + 2   // slightly tighter than Full
        case .thumbnails: return 56
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        return false  // We handle selection manually
    }

    func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
        let id = tableColumn.identifier.rawValue
        // Only columns backed by a SortColumn are clickable to sort (perms is
        // computed lazily at display time and isn't stored, so it's excluded).
        guard PanelState.SortColumn(columnIdentifier: id) != nil else { return }
        fileDelegate?.fileTableView(self, didClickColumn: id)
    }
}

// MARK: - Custom Cell Views

/// Vertically-centered single-line label cell for the Size/Modified columns,
/// so their text lines up with the (centered) Name column instead of sitting at
/// the top of the row.
final class MetaCellView: NSView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = alignment
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

class FileCellView: NSView, NSTextFieldDelegate {
    private let textField: NSTextField
    private let triangle = NSButton()
    private let iconView = NSImageView()
    private var indentConstraint: NSLayoutConstraint!
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private static let indentUnit: CGFloat = 14

    /// Called when the disclosure triangle is clicked (expand/collapse a folder).
    var onToggleExpand: (() -> Void)?
    /// Called with the new name when an inline rename is committed.
    var onCommitRename: ((String) -> Void)?
    /// Called when editing ends (commit or cancel) so the owner can restore
    /// keyboard focus to the table.
    var onEndRename: (() -> Void)?
    /// Event monitor active during a rename that lets function keys (F3–F8)
    /// abandon the edit and run their panel action instead.
    private var renameKeyMonitor: Any?
    /// Forwards a function key pressed during editing to the panel (after the
    /// rename has been torn down) so it runs the matching action.
    var onFunctionKey: ((NSEvent) -> Void)?
    private var renameOriginalName: String?

    init(identifier: NSUserInterfaceItemIdentifier) {
        textField = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        self.identifier = identifier

        triangle.isBordered = false
        triangle.bezelStyle = .regularSquare
        triangle.imagePosition = .imageOnly
        triangle.imageScaling = .scaleProportionallyDown
        triangle.contentTintColor = .secondaryLabelColor
        triangle.target = self
        triangle.action = #selector(toggleClicked)
        triangle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(triangle)

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        addSubview(textField)
        textField.translatesAutoresizingMaskIntoConstraints = false

        // Layout: [indent] triangle → icon → name. The whole group shifts right
        // with depth, so the triangle is always before the icon (Finder-style).
        indentConstraint = triangle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 24)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            indentConstraint,
            triangle.centerYAnchor.constraint(equalTo: centerYAnchor),
            triangle.widthAnchor.constraint(equalToConstant: 12),
            triangle.heightAnchor.constraint(equalToConstant: 12),
            iconView.leadingAnchor.constraint(equalTo: triangle.trailingAnchor, constant: 2),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint, iconHeightConstraint,
            textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggleClicked() { onToggleExpand?() }

    // MARK: - Inline rename

    var isRenaming: Bool { renameOriginalName != nil }

    /// Turns the name label into an editable field, selecting the base name
    /// (without extension) like Finder.
    func beginRename(currentName: String) {
        guard renameOriginalName == nil else { return }
        renameOriginalName = currentName
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBordered = true
        textField.bezelStyle = .squareBezel
        textField.drawsBackground = true
        textField.backgroundColor = .textBackgroundColor
        textField.textColor = .labelColor
        textField.delegate = self
        window?.makeFirstResponder(textField)
        // While editing, a function key (F5 copy, F6 move, F8 delete, …) should
        // abandon the rename and run that action — not type into the field.
        renameKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.renameOriginalName != nil else { return event }
            let fnKeys: Set<UInt16> = [99, 118, 96, 97, 98, 100]   // F3 F4 F5 F6 F7 F8
            guard fnKeys.contains(event.keyCode) else { return event }
            self.endRename(commit: false)                          // leave rename (revert)
            self.onFunctionKey?(event)                             // → panel action (async)
            return nil
        }
        if let editor = textField.currentEditor() {
            let ns = currentName as NSString
            let base = ns.deletingPathExtension
            let len = (base.isEmpty || base == currentName) ? currentName.count : base.count
            editor.selectedRange = NSRange(location: 0, length: len)
        }
    }

    private func endRename(commit: Bool) {
        guard let original = renameOriginalName else { return }
        renameOriginalName = nil
        if let m = renameKeyMonitor { NSEvent.removeMonitor(m); renameKeyMonitor = nil }
        let newName = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.delegate = nil
        // Restore keyboard focus to the file table so shortcuts (F5/F6/F8…) work
        // again — otherwise the responder is left at nil after editing ends.
        if let restore = onEndRename {
            restore()
        } else if let win = window, win.firstResponder is NSText {
            win.makeFirstResponder(nil)
        }
        if commit && !newName.isEmpty && newName != original {
            onCommitRename?(newName)
        } else {
            textField.stringValue = original   // revert
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { endRename(commit: true); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Commit on focus loss (e.g. clicking elsewhere) unless already handled.
        if isRenaming { endRename(commit: true) }
    }

    func configure(text: String, isDirectory: Bool, isHidden: Bool, isSymlink: Bool,
                   isCursor: Bool, isSelected: Bool, isActive: Bool,
                   depth: Int = 0, isExpandable: Bool = false, isExpanded: Bool = false,
                   icon: NSImage? = nil, iconSide: CGFloat = 24, iconTint: NSColor? = nil) {
        textField.stringValue = text
        textField.font = isDirectory ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)
        textField.alphaValue = isHidden ? 0.5 : 1.0

        // Icon (now part of the name cell, after the triangle).
        iconView.image = icon
        iconView.contentTintColor = iconTint
        iconView.alphaValue = isHidden ? 0.5 : 1.0
        if iconWidthConstraint.constant != iconSide {
            iconWidthConstraint.constant = iconSide
            iconHeightConstraint.constant = iconSide
        }

        // Indentation + disclosure triangle for expandable folders.
        indentConstraint.constant = 2 + CGFloat(depth) * Self.indentUnit
        triangle.isHidden = !isExpandable
        let symbol = isExpanded ? "chevron.down" : "chevron.right"
        triangle.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))

        // Color
        if AppSettings.colorByType {
            textField.textColor = FileTypeColor.color(name: text, isDirectory: isDirectory, isSymlink: isSymlink)
        } else if isSymlink {
            textField.textColor = .systemBlue
        } else {
            textField.textColor = .labelColor
        }
    }
}

class NCRowView: NSTableRowView {
    var isCursorRow: Bool = false
    var isSelectedItem: Bool = false
    var isPanelActive: Bool = false
    var isOddRow: Bool = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
    }

    override var isSelected: Bool {
        get { false }
        set { }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if isSelectedItem {
            if isPanelActive {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.4).setFill()
            } else {
                NSColor.secondarySelectedControlColor.setFill()
            }
            bounds.fill()
        } else if isCursorRow {
            if isPanelActive {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.7).setFill()
            } else {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).setFill()
            }
            bounds.fill()
        } else if isOddRow {
            // Zebra striping: tint odd rows slightly lighter so rows are easier
            // to tell apart. A low-alpha label color adapts to light/dark themes.
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            bounds.fill()
        }
    }
}

// MARK: - System Services support
//
// Lets the macOS Services menu (Finder-style) act on the selected files. The
// file table is the first responder, so AppKit walks the responder chain here
// to discover what the selection can vend and which services apply. The context
// menu stashes the selection's local file URLs in `serviceURLs` (from the same
// panelState selection the rest of the menu uses) just before showing.
extension NCTableView: NSServicesMenuRequestor {
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
