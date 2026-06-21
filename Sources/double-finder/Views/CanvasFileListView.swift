import AppKit

/// Owner-drawn file list — the Double Commander (`TDrawGrid`) approach: the whole
/// list is ONE view. `draw(_:)` paints the visible rows directly (cached icon
/// bitmaps blitted in, text drawn with NSString), so there is no NSView-per-cell
/// hierarchy and the window server composites a single layer. Cursor/selection
/// moves invalidate only the affected row rects, so a keystroke repaints ~2 rows
/// instead of reconfiguring a whole NSTableView.
///
/// Prototype scope: Full-mode columns (Name / Size / Modified), icon, cursor +
/// selection highlight, scrolling, click + arrow keys. Used behind a bench flag
/// to A/B the per-cursor-move cost against NSTableView on old hardware.
final class CanvasFileListView: NSView {

    // MARK: Public model (mirrors the slice of FileTableView the panel feeds)

    var items: [FileItem] = [] {
        didSet { sizeToFit(); needsDisplay = true }
    }
    var cursorIndex: Int = 0 {
        didSet {
            guard cursorIndex != oldValue else { return }
            invalidateRow(oldValue); invalidateRow(cursorIndex)   // repaint just 2 rows
        }
    }
    var selectedItems: Set<UUID> = [] {
        didSet {
            for (i, item) in items.enumerated()
            where oldValue.contains(item.id) != selectedItems.contains(item.id) {
                invalidateRow(i)
            }
        }
    }
    var isActivePanel = false { didSet { needsDisplay = true } }

    var onClickRow: ((_ row: Int, _ extend: Bool, _ toggle: Bool) -> Void)?
    var onDoubleClickRow: ((Int) -> Void)?
    var onArrow: ((_ delta: Int) -> Void)?

    let rowHeight: CGFloat = 22
    private let iconSide: CGFloat = 16
    private var iconCache: [String: NSImage] = [:]   // path → resolved icon (cached, like DC's IconID)

    override var isFlipped: Bool { true }              // top-left origin, rows go down
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { false }

    // MARK: Layout

    private func sizeToFit() {
        let w = max(enclosingScrollView?.contentSize.width ?? bounds.width, 480)
        setFrameSize(NSSize(width: w, height: CGFloat(items.count) * rowHeight))
    }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize) }

    private func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
    }
    private func invalidateRow(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        setNeedsDisplay(rowRect(row))
    }

    // MARK: Drawing — the whole list in one pass (only the dirty rows)

    private static let nameX: CGFloat = 4
    private var sizeColX: CGFloat { bounds.width - 240 }
    private var dateColX: CGFloat { bounds.width - 150 }

    /// Bench hook: called after each draw with (milliseconds, rowsDrawn).
    var onDrawMS: ((Double, Int) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        let _t0 = onDrawMS != nil ? Date() : nil
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        guard rowHeight > 0, !items.isEmpty else { return }
        let first = max(0, Int(dirtyRect.minY / rowHeight))
        let last = min(items.count - 1, Int((dirtyRect.maxY - 0.001) / rowHeight))
        guard first <= last else { return }
        defer { if let t0 = _t0 { onDrawMS?(Date().timeIntervalSince(t0) * 1000, last - first + 1) } }

        let textColor = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let nameFont = NSFont.systemFont(ofSize: 12)
        let metaFont = NSFont.systemFont(ofSize: 11)

        for row in first...last {
            let r = rowRect(row)
            let item = items[row]
            let selected = selectedItems.contains(item.id)
            let cursor = row == cursorIndex

            // Row background (alternating + selection/cursor highlight) — one fill.
            if selected {
                (isActivePanel ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.40)
                               : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
                r.fill()
            } else if cursor && isActivePanel {
                NSColor.selectedContentBackgroundColor.withAlphaComponent(0.20).setFill()
                r.fill()
            } else if row % 2 == 1 {
                NSColor.controlAlternatingRowBackgroundColors[1].setFill()
                r.fill()
            }
            if cursor {   // cursor outline
                NSColor.selectedContentBackgroundColor.setStroke()
                let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)); p.lineWidth = 1; p.stroke()
            }

            let fg = selected && isActivePanel ? NSColor.alternateSelectedControlTextColor : textColor
            let yMid = r.minY + (rowHeight - iconSide) / 2

            // Icon — blit the cached bitmap (resolved once per path).
            icon(for: item).draw(in: NSRect(x: Self.nameX, y: yMid, width: iconSide, height: iconSide))

            // Name
            let nameRect = NSRect(x: Self.nameX + iconSide + 4, y: r.minY + 3,
                                  width: sizeColX - (Self.nameX + iconSide + 8), height: rowHeight - 5)
            (item.name as NSString).draw(in: nameRect, withAttributes: [
                .font: nameFont, .foregroundColor: fg, .paragraphStyle: para])

            // Size + Modified (right-ish columns)
            let sizeStr = item.isDirectory ? "" : item.formattedSize
            (sizeStr as NSString).draw(in: NSRect(x: sizeColX, y: r.minY + 3, width: 84, height: rowHeight - 5),
                                       withAttributes: [.font: metaFont, .foregroundColor: secondary, .paragraphStyle: para])
            let df = Self.dateFormatter
            (df.string(from: item.modified) as NSString).draw(
                in: NSRect(x: dateColX, y: r.minY + 3, width: 146, height: rowHeight - 5),
                withAttributes: [.font: metaFont, .foregroundColor: secondary, .paragraphStyle: para])
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    /// Icon for a row, resolved once via NSWorkspace and cached as a bitmap — DC's
    /// `IconID` + `PixMapManager.DrawBitmap` equivalent. Never re-fetched on redraw.
    private func icon(for item: FileItem) -> NSImage {
        if let c = iconCache[item.path] { return c }
        let img: NSImage
        if item.name == ".." {
            img = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil) ?? NSImage()
        } else if FileManager.default.fileExists(atPath: item.path) {
            img = NSWorkspace.shared.icon(forFile: item.path)
        } else {
            img = NSWorkspace.shared.icon(for: .data)
        }
        img.size = NSSize(width: iconSide, height: iconSide)
        iconCache[item.path] = img
        return img
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let row = Int(p.y / rowHeight)
        guard row >= 0, row < items.count else { return }
        if event.clickCount == 2 { onDoubleClickRow?(row) }
        else { onClickRow?(row, event.modifierFlags.contains(.shift), event.modifierFlags.contains(.command)) }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onArrow?(1)    // down
        case 126: onArrow?(-1)   // up
        default: super.keyDown(with: event)
        }
    }
}

// MARK: - Prototype bench harness

/// Stands up a single window with `CanvasFileListView` (or `FileListBodyView`)
/// over a directory so the owner-drawn redraw cost can be measured + felt.
///
/// - `DF_CANVAS_BENCH=/dir` — uses the original `CanvasFileListView`.
/// - `DF_FILELIST_BENCH=/dir` — uses the new `FileListBodyView` (Task 4+).
///
/// Never returns (runs its own app loop).
enum CanvasBench {
    private static var keepAlive: [AnyObject] = []

    // MARK: FileListBodyView bench (DF_FILELIST_BENCH)

    static func runFileListBench(dir: String, app: NSApplication) {
        let items = loadDir(dir)
        let winRect = NSRect(x: 120, y: 120, width: 760, height: 760)
        let win = NSWindow(contentRect: winRect,
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "FileListBodyView bench — \(dir) (\(items.count) items)"

        let contentRect = win.contentLayoutRect
        let headerHeight: CGFloat = 22

        // Container fills the window content area.
        // AppKit content view uses bottom-left origin (non-flipped).
        // Header sits at the top → y = contentRect.height - headerHeight.
        // Scroll view fills the rest below the header.
        let container = NSView(frame: contentRect)
        container.autoresizingMask = [.width, .height]

        // --- Header (Task 9) ---
        let headerY = contentRect.height - headerHeight
        let header = FileListHeaderView(frame: NSRect(x: 0, y: headerY,
                                                      width: contentRect.width, height: headerHeight))
        header.autoresizingMask = [.width, .minYMargin]
        header.sortColumnID = "name"
        header.sortAscending = true
        container.addSubview(header)

        // --- Scroll view below the header ---
        let scrollRect = NSRect(x: 0, y: 0,
                                width: contentRect.width, height: contentRect.height - headerHeight)
        let scroll = NSScrollView(frame: scrollRect)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]

        let list = FileListBodyView(frame: NSRect(x: 0, y: 0, width: 760, height: 10))
        list.viewMode = .full
        list.isActivePanel = true
        list.items = items          // triggers reloadLayout + icon prefetch
        scroll.documentView = list
        container.addSubview(scroll)
        win.contentView = container

        // --- Header callbacks ---
        header.onSort = { [weak header, weak win] colID in
            guard let header = header else { return }
            if header.sortColumnID == colID {
                header.sortAscending = !header.sortAscending
            } else {
                header.sortColumnID = colID
                header.sortAscending = true
            }
            let msg = "onSort → \(colID) asc=\(header.sortAscending)\n"
            win?.title = "FileListBodyView bench — sorted by \(colID)"
            let url = URL(fileURLWithPath: "/tmp/df-filelist.txt")
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(msg.data(using: .utf8)!); try? fh.close()
            } else { try? msg.write(to: url, atomically: true, encoding: .utf8) }
        }
        header.onLayoutChanged = { [weak header, weak list, weak scroll] in
            list?.needsDisplay = true
            scroll?.needsDisplay = true
            header?.needsDisplay = true
            let msg = "onLayoutChanged — columnWidths=\(AppSettings.columnWidths)\n"
            let url = URL(fileURLWithPath: "/tmp/df-filelist.txt")
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(msg.data(using: .utf8)!); try? fh.close()
            } else { try? msg.write(to: url, atomically: true, encoding: .utf8) }
        }

        // --- Stub delegate: logs every callback to /tmp/df-filelist.txt ---
        let stub = BenchFileDelegate(list: list, scroll: scroll)
        list.fileDelegate = stub

        // Number keys 1/2/3 → switch viewMode for GUI verification of Task 5.
        // (Still goes through the bench onModeSwitch path since fileDelegate != nil
        //  only affects mouseDown/keyDown paths; mode-switch keys are unrelated.)
        list.onModeSwitch = { [weak list, weak win] mode in
            guard let list = list, let win = win else { return }
            list.viewMode = mode
            win.title = "FileListBodyView bench — \(dir) (\(items.count) items) [mode: \(mode.title)]"
        }

        keepAlive = [win, container, header, scroll, list, stub]
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(list)
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
        exit(0)
    }
}

// MARK: - Stub delegate for the FileListBodyView bench

/// Logs each FileTableViewDelegate callback to /tmp/df-filelist.txt and also
/// drives the cursor/selection so the bench remains interactive.
private final class BenchFileDelegate: FileTableViewDelegate {
    private weak var list: FileListBodyView?
    private weak var scroll: NSScrollView?

    init(list: FileListBodyView, scroll: NSScrollView) {
        self.list = list
        self.scroll = scroll
        log("=== BenchFileDelegate attached ===")
    }

    private func log(_ msg: String) {
        let line = msg + "\n"
        let url = URL(fileURLWithPath: "/tmp/df-filelist.txt")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func fileTableView(_ tableView: NSView, didClickRow row: Int, extend: Bool, toggle: Bool) {
        log("didClickRow row=\(row) extend=\(extend) toggle=\(toggle)")
        guard let list = list else { return }
        // Drive cursor & selection so the bench stays interactive.
        list.cursorIndex = row
        if !extend && !toggle { list.selectedItems = [list.items[row].id] }
        scrollRowVisible(row)
    }

    func fileTableView(_ tableView: NSView, didDoubleClickItem item: FileItem) {
        log("didDoubleClickItem item=\(item.name)")
    }

    func fileTableView(_ tableView: NSView, didPressEnterOnItem item: FileItem) {
        log("didPressEnterOnItem item=\(item.name)")
    }

    func fileTableViewDidChangeCursor(_ tableView: NSView, to index: Int) {
        log("didChangeCursor to=\(index)")
        list?.cursorIndex = index
        scrollRowVisible(index)
    }

    func fileTableViewWantsActivation(_ tableView: NSView) {
        log("fileTableViewWantsActivation")
    }

    func fileTableView(_ tableView: NSView, didPressSpaceOnIndex index: Int) {
        log("didPressSpaceOnIndex index=\(index)")
    }

    func fileTableView(_ tableView: NSView, didClickColumn identifier: String) {
        log("didClickColumn identifier=\(identifier)")
    }

    func fileTableView(_ tableView: NSView, didToggleExpand item: FileItem) {
        log("didToggleExpand item=\(item.name)")
        guard let list = list else { return }
        if list.expandedPaths.contains(item.path) {
            list.expandedPaths.remove(item.path)
        } else {
            list.expandedPaths.insert(item.path)
        }
    }

    func fileTableView(_ tableView: NSView, didRename item: FileItem, to newName: String) {
        log("didRename item=\(item.name) to=\(newName)")
    }

    func fileTableView(_ tableView: NSView, didDropFiles urls: [URL], move: Bool) {
        log("didDropFiles count=\(urls.count) move=\(move)")
    }

    private func scrollRowVisible(_ row: Int) {
        guard let list = list, let scroll = scroll else { return }
        let clipH = scroll.contentView.bounds.height
        let rowH = list.geometry.rowHeight
        let rowY = CGFloat(row) * rowH
        if rowY < scroll.contentView.bounds.minY {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rowY)))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if rowY + rowH > scroll.contentView.bounds.maxY {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: rowY + rowH - clipH))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}

// Reopen the enum so the compiler sees it as a continuation.
extension CanvasBench {

    // MARK: FileListView bench (DF_FILELISTVIEW_BENCH)
    //
    // Uses the Task-10 FileListView composite (header + body composed together)
    // so GUI verification can confirm:
    //   • Header visible in .full / hidden in .brief + .thumbnails
    //   • Columns in header align with body rows
    //   • Scrolling works, sort indicator shows, clicking a column fires didClickColumn
    //   • Resizing a divider reflows header + body together
    //
    // Keys 1/2/3 switch view modes; arrow keys navigate; 'r' renames at cursor.

    static func runFileListViewBench(dir: String, app: NSApplication) {
        let items = loadDir(dir)
        let winRect = NSRect(x: 120, y: 120, width: 760, height: 760)
        let win = NSWindow(contentRect: winRect,
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "FileListView bench — \(dir) (\(items.count) items)"

        // FileListView fills the full window content area.
        let flv = FileListView(frame: win.contentLayoutRect)
        flv.autoresizingMask = [.width, .height]
        flv.viewMode = .full
        flv.isActivePanel = true
        flv.items = items

        // Sort indicator starts on "name" ascending.
        flv.updateSortIndicator(column: "name", ascending: true)

        // --- Stub delegate wired to the composite view ---
        let stub = BenchFileListViewDelegate(flv: flv)
        flv.fileDelegate = stub

        // Mode-switch keys 1/2/3.
        // Note: the body only handles these when fileDelegate == nil.
        // With a delegate set, key events go up the responder chain.
        // The FileListView bench wires the body's onModeSwitch AND installs
        // a local event monitor to intercept mode keys at the app level.
        flv.body.onModeSwitch = { [weak flv, weak win] mode in
            guard let flv = flv, let win = win else { return }
            flv.viewMode = mode
            win.title = "FileListView bench — \(dir) (\(items.count) items) [mode: \(mode.title)]"
        }

        // Local key monitor: intercept 1/2/3 (keyCodes 18/19/20) while this
        // bench window is key, and drive mode-switch via onModeSwitch directly.
        let modeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak flv, weak win] event in
            guard let flv = flv, let win = win, win.isKeyWindow else { return event }
            guard event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty else { return event }
            let modeMap: [UInt16: FileViewMode] = [18: .full, 19: .brief, 20: .thumbnails]
            if let mode = modeMap[event.keyCode] {
                flv.viewMode = mode
                win.title = "FileListView bench — \(dir) (\(items.count) items) [mode: \(mode.title)]"
                return nil   // consume
            }
            return event
        }

        win.contentView = flv
        keepAlive.append(contentsOf: [win, flv, stub, modeMonitor as AnyObject] as [AnyObject])
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(flv.firstResponderTarget)
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
        exit(0)
    }

    // (bench helpers below)

    // MARK: Original CanvasFileListView bench (DF_CANVAS_BENCH)

    static func run(dir: String, app: NSApplication) {
        let items = loadDir(dir)
        let win = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 760, height: 760),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = "Canvas bench — \(dir) (\(items.count) items)"

        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let list = CanvasFileListView(frame: NSRect(x: 0, y: 0, width: 760, height: 10))
        list.items = items
        scroll.documentView = list
        win.contentView = scroll

        // Log every redraw's cost (ms + rows) so we can compare with NSTableView's
        // ~30ms-per-cursor-move baseline.
        list.onDrawMS = { ms, rows in
            let line = "canvas draw \(String(format:"%.2f",ms))ms rows=\(rows)\n"
            let u = URL(fileURLWithPath: "/tmp/df-canvas.txt")
            if let fh = try? FileHandle(forWritingTo: u) { fh.seekToEndOfFile(); fh.write(line.data(using:.utf8)!); try? fh.close() }
            else { try? line.write(to: u, atomically: true, encoding: .utf8) }
        }
        list.onArrow = { [weak list] delta in
            guard let list = list else { return }
            let n = list.items.count
            list.cursorIndex = max(0, min(n - 1, list.cursorIndex + delta))
            list.scrollToRowVisible(list.cursorIndex)
        }
        list.onClickRow = { [weak list] row, _, _ in list?.cursorIndex = row }

        keepAlive = [win, scroll, list]
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(list)
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        app.run()
        exit(0)
    }

    private static func loadDir(_ dir: String) -> [FileItem] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        var out: [FileItem] = []
        for name in names.sorted() {
            let path = (dir as NSString).appendingPathComponent(name)
            let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
            var isDir: ObjCBool = false; fm.fileExists(atPath: path, isDirectory: &isDir)
            out.append(FileItem(
                id: UUID(), name: name, path: path, isDirectory: isDir.boolValue,
                isArchive: false, size: (attrs[.size] as? Int64) ?? 0,
                modified: (attrs[.modificationDate] as? Date) ?? Date(),
                isHidden: name.hasPrefix("."), isSymlink: false, permissions: "rw-r--r--"))
        }
        return out
    }
}

extension CanvasFileListView {
    /// Scrolls the given row into view (used by the bench arrow handler).
    func scrollToRowVisible(_ row: Int) {
        scrollToVisible(rowRectPublic(row))
    }
    private func rowRectPublic(_ row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * rowHeight, width: bounds.width, height: rowHeight)
    }
}

// MARK: - Stub delegate for the FileListView bench (Task 10)

/// Drives cursor/selection and logs each callback to /tmp/df-filelistview.txt.
/// Wires arrow-key navigation through `ensureRowVisible` via the `FileListView` shell.
private final class BenchFileListViewDelegate: FileTableViewDelegate {
    private weak var flv: FileListView?

    init(flv: FileListView) {
        self.flv = flv
        log("=== BenchFileListViewDelegate attached — FileListView (Task 10) ===")
    }

    private func log(_ msg: String) {
        let line = msg + "\n"
        let url = URL(fileURLWithPath: "/tmp/df-filelistview.txt")
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8)!)
            try? fh.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func fileTableView(_ tableView: NSView, didClickRow row: Int, extend: Bool, toggle: Bool) {
        log("didClickRow row=\(row) extend=\(extend) toggle=\(toggle)")
        guard let flv = flv else { return }
        flv.cursorIndex = row
        if !extend && !toggle { flv.selectedItems = [flv.items[row].id] }
        flv.ensureRowVisible(row)
    }

    func fileTableView(_ tableView: NSView, didDoubleClickItem item: FileItem) {
        log("didDoubleClickItem item=\(item.name)")
    }

    func fileTableView(_ tableView: NSView, didPressEnterOnItem item: FileItem) {
        log("didPressEnterOnItem item=\(item.name)")
    }

    func fileTableViewDidChangeCursor(_ tableView: NSView, to index: Int) {
        log("didChangeCursor to=\(index)")
        flv?.cursorIndex = index
        flv?.ensureRowVisible(index)
    }

    func fileTableViewWantsActivation(_ tableView: NSView) {
        log("fileTableViewWantsActivation")
    }

    func fileTableView(_ tableView: NSView, didPressSpaceOnIndex index: Int) {
        log("didPressSpaceOnIndex index=\(index)")
    }

    func fileTableView(_ tableView: NSView, didClickColumn identifier: String) {
        log("didClickColumn identifier=\(identifier)")
        guard let flv = flv else { return }
        // Toggle sort direction on the same column; switch to ascending for a new column.
        if flv.body.sortColumnID == identifier {
            flv.updateSortIndicator(column: identifier, ascending: !flv.body.sortAscending)
        } else {
            flv.updateSortIndicator(column: identifier, ascending: true)
        }
    }

    func fileTableView(_ tableView: NSView, didToggleExpand item: FileItem) {
        log("didToggleExpand item=\(item.name)")
        guard let flv = flv else { return }
        if flv.expandedPaths.contains(item.path) {
            flv.expandedPaths.remove(item.path)
        } else {
            flv.expandedPaths.insert(item.path)
        }
    }

    func fileTableView(_ tableView: NSView, didRename item: FileItem, to newName: String) {
        log("didRename item=\(item.name) to=\(newName)")
    }

    func fileTableView(_ tableView: NSView, didDropFiles urls: [URL], move: Bool) {
        log("didDropFiles count=\(urls.count) move=\(move)")
    }
}
