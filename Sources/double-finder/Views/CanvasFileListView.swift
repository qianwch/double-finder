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

/// Stands up a single window with `CanvasFileListView` over a directory so the
/// owner-drawn redraw cost can be measured + felt. Launched by the DF_CANVAS_BENCH
/// env var; never returns (runs its own app loop).
enum CanvasBench {
    private static var keepAlive: [AnyObject] = []

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
