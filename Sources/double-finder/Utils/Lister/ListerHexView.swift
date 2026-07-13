import AppKit

/// Hex-mode document view (design §4): draws only visible 16-byte rows, bytes
/// fetched through a true 64KB-page LRU cache over ListerSource (hits refresh
/// recency; eviction drops the least-recently-used page). Wrapped in an
/// NSScrollView by the controller. Handles its own scroll keys.
@MainActor
final class ListerHexView: NSView {
    static let pageSize: UInt64 = 64 << 10
    static let maxPages = 32

    var onStatusChange: (() -> Void)?
    var onReadError: (() -> Void)?           // fired once per load on I/O error (design §8)

    private var source: ListerSource?
    private var digits = 8
    private var readErrorNotified = false
    private var highlightRange: (offset: UInt64, count: Int)?
    private var pages: [UInt64: Data] = [:]
    private var lru: [UInt64] = []

    private var fontSize: CGFloat = 12
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var charW: CGFloat = 8
    private var rowHeight: CGFloat = 16
    private let pad: CGFloat = 8

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func load(source: ListerSource) {
        self.source = source
        digits = HexFormatter.offsetDigits(fileLength: source.length)
        charW = ("0" as NSString).size(withAttributes: [.font: font]).width
        highlightRange = nil; pages = [:]; lru = []; readErrorNotified = false
        let rows = (source.length + 15) / 16
        // Width = max(intrinsic row width, clip width): a narrow window gets a
        // horizontal scroller instead of a clipped ASCII column.
        setFrameSize(NSSize(width: max(intrinsicContentWidth,
                                       enclosingScrollView?.contentSize.width ?? 800),
                            height: max(rowHeight, CGFloat(rows) * rowHeight)))
        // Hard clip reset (belt-and-braces with the draw guard): after shrinking
        // the frame, force the clip back to origin so no stale deep-scroll offset
        // survives the reload.
        if let sv = enclosingScrollView {
            sv.contentView.scroll(to: .zero)
            sv.reflectScrolledClipView(sv.contentView)
        }
        scroll(.zero)
        needsDisplay = true
    }

    /// Intrinsic width of one full row: offset column (digits + 2-char gap) +
    /// hex column (49 cells incl. the mid-gap) + ASCII column (16) + margins.
    private var intrinsicContentWidth: CGFloat {
        pad + CGFloat(digits + 2 + 49 + 16) * charW + 4 * pad
    }

    private var rowCount: UInt64 { ((source?.length ?? 0) + 15) / 16 }

    private func bytes(forRow row: UInt64) -> [UInt8] {
        guard let source else { return [] }
        let offset = row * 16
        let page = offset / Self.pageSize
        if pages[page] == nil {
            guard let d = source.read(offset: page * Self.pageSize, count: Int(Self.pageSize)) else {
                if !readErrorNotified { readErrorNotified = true; onReadError?() }
                return []
            }
            pages[page] = d
            lru.append(page)
            if lru.count > Self.maxPages { pages[lru.removeFirst()] = nil }
        } else if let i = lru.firstIndex(of: page) {
            lru.remove(at: i); lru.append(page)
        }
        guard let d = pages[page] else { return [] }
        let local = Int(offset - page * Self.pageSize)
        guard local < d.count else { return [] }
        return [UInt8](d[(d.startIndex + local)..<min(d.endIndex, d.startIndex + local + 16)])
    }

    // Column origins.
    private var hexX: CGFloat { pad + CGFloat(digits + 2) * charW }
    private var asciiX: CGFloat { hexX + CGFloat(16 * 3 + 1) * charW + 2 * pad }
    /// x of hex byte cell i (accounts for the mid-gap after byte 8).
    private func cellX(_ i: Int) -> CGFloat { hexX + CGFloat(i * 3 + (i >= 8 ? 1 : 0)) * charW }

    override func draw(_ dirtyRect: NSRect) {
        guard source != nil else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
        let dim: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let first = UInt64(max(0, Int(dirtyRect.minY / rowHeight)))
        let last = min(rowCount == 0 ? 0 : rowCount - 1, UInt64(dirtyRect.maxY / rowHeight) + 1)
        // A redraw scheduled against the OLD (taller) bounds can arrive right
        // after a smaller file was loaded (file switch / mode re-load while
        // scrolled deep): dirtyRect then lies entirely below the new content,
        // first > last, and an inverted ClosedRange traps. Smoke-test caught.
        guard rowCount > 0, first <= last else { return }
        for row in first...last {
            let y = CGFloat(row) * rowHeight + 1
            let b = bytes(forRow: row)
            let hr = HexFormatter.row(offset: row * 16, bytes: b, digits: digits)
            if let hl = highlightRange {
                let rowStart = row * 16, rowEnd = rowStart + UInt64(b.count)
                let hlEnd = hl.offset + UInt64(hl.count)
                if hl.offset < rowEnd && hlEnd > rowStart {
                    NSColor.selectedTextBackgroundColor.setFill()
                    let s = Int(max(hl.offset, rowStart) - rowStart)
                    let e = Int(min(hlEnd, rowEnd) - rowStart)
                    NSRect(x: cellX(s), y: y - 1,
                           width: cellX(e - 1) + 2 * charW - cellX(s), height: rowHeight).fill()
                    NSRect(x: asciiX + CGFloat(s) * charW, y: y - 1,
                           width: CGFloat(e - s) * charW, height: rowHeight).fill()
                }
            }
            (hr.offset as NSString).draw(at: NSPoint(x: pad, y: y), withAttributes: dim)
            (hr.hex as NSString).draw(at: NSPoint(x: hexX, y: y), withAttributes: attrs)
            (hr.ascii as NSString).draw(at: NSPoint(x: asciiX, y: y), withAttributes: attrs)
        }
    }

    func scrollToOffset(_ offset: UInt64) {
        scroll(NSPoint(x: 0, y: CGFloat(offset / 16) * rowHeight))
        onStatusChange?()
    }

    func highlight(offset: UInt64, count: Int) {
        guard count >= 1 else { return }
        highlightRange = (offset, count)
        scrollToOffset(offset)
        needsDisplay = true
    }

    var topVisibleOffset: UInt64 {
        UInt64(max(0, visibleRect.minY / rowHeight)) * 16
    }

    var percent: Int {
        guard let source, source.length > 0 else { return 100 }
        return Int(min(100, (topVisibleOffset * 100) / source.length))
    }

    /// ⌘=/⌘-/⌘0 zoom. Metrics (font/charW/rowHeight) always update; with
    /// `reapply` and a loaded source the frame is re-derived and the top
    /// visible offset re-anchored (captured BEFORE rowHeight changes).
    func setFontSize(_ size: CGFloat, reapply: Bool) {
        guard size != fontSize else { return }
        let anchor = (reapply && source != nil) ? topVisibleOffset : 0
        fontSize = size
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        charW = ("0" as NSString).size(withAttributes: [.font: font]).width
        rowHeight = size + 4
        guard reapply, let source else { return }
        let rows = (source.length + 15) / 16
        setFrameSize(NSSize(width: max(intrinsicContentWidth,
                                       enclosingScrollView?.contentSize.width ?? 800),
                            height: max(rowHeight, CGFloat(rows) * rowHeight)))
        scrollToOffset(anchor)
        needsDisplay = true
    }

    func pageDown() { scrollPageDown(nil) }
    func focus() { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        // Vertical keys keep the current horizontal scroll (visibleRect.minX),
        // so arrowing after a horizontal scroll doesn't snap back to column 0.
        switch event.keyCode {
        case 126: scroll(NSPoint(x: visibleRect.minX, y: max(0, visibleRect.minY - rowHeight * 3)))
        case 125: scroll(NSPoint(x: visibleRect.minX, y: visibleRect.minY + rowHeight * 3))
        case 116: scrollPageUp(nil)
        case 121: scrollPageDown(nil)
        case 115: scroll(NSPoint(x: visibleRect.minX, y: 0))
        case 119: scroll(NSPoint(x: visibleRect.minX, y: frame.height - visibleRect.height))
        default: super.keyDown(with: event); return
        }
        onStatusChange?()
    }
}
