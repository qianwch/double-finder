import AppKit
import PDFKit
import CoreImage
import DoubleFinderPluginKit

/// Light / Dark for the PDF pages, independent of the app's appearance.
/// Persisted in UserDefaults (`PDFAppearance`: "light" / "dark", absent =
/// follow the app); every mounted PDF view — Lister windows and the Quick
/// View pane alike — follows the one value.
enum PDFAppearanceOverride {
    static let defaultsKey = "PDFAppearance"
    static let changed = Notification.Name("PDFAppearanceChanged")

    /// nil = follow the app's appearance.
    @MainActor static var wantsDark: Bool? {
        get {
            switch UserDefaults.standard.string(forKey: defaultsKey) {
            case "dark": return true
            case "light": return false
            default: return nil
            }
        }
        set {
            guard newValue != wantsDark else { return }
            if let newValue {
                UserDefaults.standard.set(newValue ? "dark" : "light", forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Effective mode for a view: the override, else the app's appearance.
    @MainActor static func isDark(for view: NSView) -> Bool {
        wantsDark ?? (view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
}

/// Built-in view plugin: PDF documents in a PDFKit `PDFView`. Dark pages are
/// rendered inverted with hues restored ("smart invert"), so text reads
/// light-on-dark while the pictures on the page are pasted back untouched.
/// Whether a page is dark follows the app's appearance by default; a
/// Light / Dark switch at the bottom of the view overrides that
/// (`PDFAppearanceOverride`, one setting shared by the Lister and the Quick
/// View pane; picking the side the app is already on clears the override).
/// Quick Look (Preview, 3) always shows the page as printed; switch this
/// plugin off in Settings ▸ Plugins and F3 hands `.pdf` straight to Quick
/// Look again.
final class PDFViewerPlugin: NSObject, DFPlugin {
    static let identifier = "net.qian.double-finder.pdf"

    var info: PluginInfo {
        MainActor.assumeIsolated { PluginInfo(identifier: Self.identifier, name: tr("PDF Viewer"), version: "1.0",
                   summary: tr("Shows PDF documents in the Lister, dark mode included"),
                   author: "Double Finder") }
    }

    private let viewer = PDFDocumentViewer()

    override init() { super.init() }

    func activate(host: PluginHost) throws {}

    var viewers: [ViewerPlugin] { [viewer] }
}

final class PDFDocumentViewer: ViewerPlugin, Sendable {
    let identifier = "pdf"
    var displayName: String { MainActor.assumeIsolated { tr("PDF Viewer") } }

    func canView(url: URL, sample: Data) -> Bool {
        url.pathExtension.lowercased() == "pdf" || sample.starts(with: Array("%PDF".utf8))
    }

    @MainActor func makeView(for url: URL) throws -> NSView {
        guard let document = ListerPDFDocument(url: url) else { throw PageError("Cannot open PDF") }
        return PDFViewerContainer(document: document)
    }
}

// MARK: - Container: outline sidebar + page view

/// What the Lister mounts: a split view with the document's outline (its
/// bookmarks / table of contents) on the left — only when the PDF has one —
/// and the `ListerPDFView` on the right. Keyboard focus and the Lister's
/// zoom actions are forwarded to the page view; clicking an outline entry
/// jumps to its destination and turning pages selects the matching entry.
final class PDFViewerContainer: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let pdfView = ListerPDFView(frame: .zero)
    private let document: ListerPDFDocument
    private let split = NSSplitView()
    private let outline = NSOutlineView()
    private var sidebar: NSScrollView?
    private var syncing = false
    /// Bottom strip with the Light / Dark switch for the pages.
    private let styleBar = NSView()
    private let modeControl = NSSegmentedControl()
    private static let styleBarHeight: CGFloat = 24

    init(document: ListerPDFDocument) {
        self.document = document
        super.init(frame: .zero)
        // The document is attached in the first real-size layout() — a PDFView
        // that receives it while still zero-sized (autolayout hosts such as the
        // Quick View pane) comes up scrolled mid-document once it grows.
        split.isVertical = true
        split.dividerStyle = .thin
        // Autoresizing keeps the page view sized between layout passes (the
        // host sets our frame right after makeView); layout() then carves the
        // style bar out of the bottom.
        split.autoresizingMask = [.width, .height]
        split.frame = bounds
        addSubview(split)
        if let root = document.outlineRoot, root.numberOfChildren > 0 {
            buildSidebar()
        }
        split.addArrangedSubview(pdfView)
        buildStyleBar()
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(syncModeControl),
                                               name: PDFAppearanceOverride.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private var dividerPlaced = false
    override func layout() {
        super.layout()
        let barH = Self.styleBarHeight
        styleBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barH)
        split.frame = NSRect(x: 0, y: barH, width: bounds.width, height: max(0, bounds.height - barH))
        modeControl.frame.origin = NSPoint(x: bounds.width - modeControl.frame.width - 6,
                                           y: (barH - modeControl.frame.height) / 2)
        // The split position only sticks once the view has a real size
        // (the Lister sizes us after makeView returns).
        if !dividerPlaced, sidebar != nil, bounds.width > 300 {
            dividerPlaced = true
            split.setPosition(240, ofDividerAt: 0)
        }
        // Size the page view NOW (NSSplitView would do it in its own pass) so
        // the document is attached to a PDFView that already has its real
        // frame: PDFKit fixes the auto-scale on first layout, and a zero-sized
        // view then "restores" the mid-document centre when it grows.
        split.adjustSubviews()
        if pdfView.document == nil, pdfView.frame.height > 50 {
            pdfView.document = document
            // PDFKit settles scale and scroll in its own first layout (and the
            // bar may still carve the frame once more): pin page 1's top after that.
            DispatchQueue.main.async { [weak self] in self?.scrollToTop() }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncModeControl()
    }

    private func scrollToTop() {
        guard let first = document.page(at: 0) else { return }
        let top = first.bounds(for: pdfView.displayBox).maxY
        pdfView.go(to: PDFDestination(page: first, at: NSPoint(x: kPDFDestinationUnspecifiedValue, y: top)))
    }

    private func buildStyleBar() {
        addSubview(styleBar)
        modeControl.segmentCount = 2
        modeControl.setLabel(tr("Light"), forSegment: 0)
        modeControl.setLabel(tr("Dark"), forSegment: 1)
        modeControl.trackingMode = .selectOne
        modeControl.controlSize = .small
        modeControl.font = .systemFont(ofSize: 11)
        modeControl.target = self
        modeControl.action = #selector(modePicked(_:))
        modeControl.sizeToFit()
        modeControl.autoresizingMask = [.minXMargin]
        styleBar.addSubview(modeControl)
        syncModeControl()
    }

    /// The switch always shows the EFFECTIVE mode (override, else the app's).
    @objc private func syncModeControl() {
        modeControl.selectedSegment = PDFAppearanceOverride.isDark(for: self) ? 1 : 0
    }

    /// Picking the side the app is already on means "follow the app" again;
    /// the other side is stored as the override. Every PDF view reloads.
    @objc private func modePicked(_ sender: NSSegmentedControl) {
        let wantDark = sender.selectedSegment == 1
        let appDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        PDFAppearanceOverride.wantsDark = wantDark == appDark ? nil : wantDark
    }

    private func buildSidebar() {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = true
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(outlineClicked)
        let sc = NSScrollView()
        sc.documentView = outline
        sc.hasVerticalScroller = true
        sc.autohidesScrollers = true
        sc.drawsBackground = true
        split.addArrangedSubview(sc)
        sc.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        sidebar = sc
        outline.reloadData()
        outline.expandItem(nil, expandChildren: false)
        if let root = document.outlineRoot {
            for i in 0..<root.numberOfChildren { outline.expandItem(root.child(at: i)) }   // first level open
        }
    }

    // Focus / actions the Lister sends to the mounted view.
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(pdfView) ?? false }
    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func resetZoom(_ sender: Any?) { pdfView.resetZoom(sender) }

    // MARK: Outline data

    private var root: PDFOutline? { document.outlineRoot }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? PDFOutline) ?? root)?.numberOfChildren ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PDFOutline) ?? root)!.child(at: index)!
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        ((item as? PDFOutline)?.numberOfChildren ?? 0) > 0
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.lineBreakMode = .byTruncatingTail
            tf.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        cell.textField?.stringValue = (item as? PDFOutline)?.label ?? ""
        cell.textField?.toolTip = cell.textField?.stringValue
        return cell
    }

    @objc private func outlineClicked() {
        guard !syncing, let item = outline.item(atRow: outline.clickedRow) as? PDFOutline else { return }
        if let dest = item.destination {
            pdfView.go(to: dest)
        } else if let action = item.action as? PDFActionGoTo {
            pdfView.go(to: action.destination)
        }
        window?.makeFirstResponder(pdfView)
    }

    /// Select the last outline entry whose page is at or before the current one.
    @objc private func pageChanged() {
        guard sidebar != nil, let page = pdfView.currentPage else { return }
        let doc = document
        let current = doc.index(for: page)
        var best: (PDFOutline, Int)?
        func walk(_ node: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let p = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page {
                    let idx = doc.index(for: p)
                    if idx <= current, idx >= (best?.1 ?? -1) { best = (child, idx) }
                }
                walk(child)
            }
        }
        if let root { walk(root) }
        guard let (item, _) = best else { return }
        syncing = true
        var chain: [PDFOutline] = []
        var parent = item.parent
        while let p = parent, p !== root { chain.append(p); parent = p.parent }
        for p in chain.reversed() { outline.expandItem(p) }        // NSOutlineView only knows expanded rows
        let row = outline.row(forItem: item)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        syncing = false
    }
}

// MARK: - View

/// `PDFView` whose pages know the current appearance. The dark rendering
/// itself happens in `ListerPDFPage.draw` (per page, pictures excluded); the
/// view only flips the document's `darkMode` flag and forces a redraw.
final class ListerPDFView: PDFView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoScales = true
        displayMode = .singlePageContinuous
        displayDirection = .vertical
        applyAppearance()
        NotificationCenter.default.addObserver(self, selector: #selector(applyAppearance),
                                               name: PDFAppearanceOverride.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var document: PDFDocument? {
        didSet { (document as? ListerPDFDocument)?.darkMode = isDark }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// The user's Light / Dark override, else the app's appearance.
    private var isDark: Bool { PDFAppearanceOverride.isDark(for: self) }

    /// App appearance changed, or the override did (here or in another PDF view).
    @objc private func applyAppearance() {
        backgroundColor = isDark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.90, alpha: 1)
        guard let doc = document as? ListerPDFDocument, doc.darkMode != isDark else { return }
        doc.darkMode = isDark
        reloadKeepingPosition(doc)
    }

    /// PDFKit caches rendered pages: detaching and re-attaching the document
    /// is the one reliable way to flush them (assigning the same document
    /// again is a no-op). Keep the reading position and zoom.
    private func reloadKeepingPosition(_ doc: ListerPDFDocument) {
        let dest = currentDestination
        let wasAuto = autoScales, factor = scaleFactor
        document = nil
        document = doc
        if wasAuto { autoScales = true } else { scaleFactor = factor }
        if let dest { go(to: dest) }
    }

    /// ⌘0 from the Lister (`zoomIn:` / `zoomOut:` are PDFView's own).
    @objc func resetZoom(_ sender: Any?) { autoScales = true }
}

// MARK: - Document / page

final class ListerPDFDocument: PDFDocument, PDFDocumentDelegate {
    private let lock = NSLock()
    private var _dark = false
    /// Read from page drawing, which PDFKit may run off the main thread.
    var darkMode: Bool {
        get { lock.withLock { _dark } }
        set { lock.withLock { _dark = newValue } }
    }

    override init?(url: URL) {
        super.init(url: url)
        delegate = self            // before any page is materialised
    }

    func classForPage() -> AnyClass { ListerPDFPage.self }
}

/// Dark rendering: the page is drawn into an offscreen bitmap at the current
/// scale, pushed through invert → hue-rotate 180° → tone (paper ≈ #1c1c1c,
/// ink ≈ #e0e0e0) and drawn back; then the regions covered by the page's
/// image XObjects (found once per page by `PDFImageFinder`) are clipped and
/// the untouched bitmap is drawn again inside them, so photos and figures
/// keep their real colours. Images that cover the whole page (scans) count as
/// the page and are inverted like text.
final class ListerPDFPage: PDFPage {
    private let lock = NSLock()
    private var cachedQuads: [[CGPoint]]?

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let maxPixels = 20_000_000

    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        guard let doc = document as? ListerPDFDocument, doc.darkMode,
              let filtered = renderDark(box: box, context: context) else {
            super.draw(with: box, to: context)
            return
        }
        context.saveGState()
        context.interpolationQuality = .none
        context.draw(filtered.dark, in: filtered.rect)
        let quads = imageQuads(box: box)
        if !quads.isEmpty {
            context.beginPath()
            for q in quads where q.count == 4 {
                context.move(to: q[0]); context.addLine(to: q[1]); context.addLine(to: q[2]); context.addLine(to: q[3])
                context.closePath()
            }
            context.clip()
            context.draw(filtered.plain, in: filtered.rect)
        }
        context.restoreGState()
    }

    /// Offscreen render of the visible part of the page + its dark variant.
    private func renderDark(box: PDFDisplayBox, context: CGContext) -> (plain: CGImage, dark: CGImage, rect: CGRect)? {
        let pageRect = CGRect(origin: .zero, size: bounds(for: box).size)
        let visible = context.boundingBoxOfClipPath.intersection(pageRect)
        guard !visible.isEmpty else { return nil }
        let ctm = context.ctm
        var sx = (ctm.a * ctm.a + ctm.b * ctm.b).squareRoot()
        var sy = (ctm.c * ctm.c + ctm.d * ctm.d).squareRoot()
        guard sx > 0, sy > 0 else { return nil }
        let pixels = visible.width * sx * visible.height * sy
        if pixels > CGFloat(Self.maxPixels) {            // huge zoom: render coarser rather than blow memory
            let k = (CGFloat(Self.maxPixels) / pixels).squareRoot()
            sx *= k; sy *= k
        }
        let w = max(1, Int((visible.width * sx).rounded(.up))), h = max(1, Int((visible.height * sy).rounded(.up)))
        guard let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        bmp.setFillColor(CGColor(gray: 1, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bmp.scaleBy(x: CGFloat(w) / visible.width, y: CGFloat(h) / visible.height)
        bmp.translateBy(x: -visible.minX, y: -visible.minY)
        super.draw(with: box, to: bmp)
        guard let plain = bmp.makeImage() else { return nil }

        // Core Image works in linear light: the tone values are linear.
        var ci = CIImage(cgImage: plain)
        ci = ci.applyingFilter("CIColorInvert")
        ci = ci.applyingFilter("CIHueAdjust", parameters: [kCIInputAngleKey: CGFloat.pi])
        ci = ci.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.74, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.74, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.74, w: 0),
            "inputBiasVector": CIVector(x: 0.012, y: 0.012, z: 0.012, w: 0),
        ])
        guard let dark = Self.ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return nil }
        return (plain, dark, visible)
    }

    /// Image quads in the draw context's space (page space of `box`).
    private func imageQuads(box: PDFDisplayBox) -> [[CGPoint]] {
        let raw: [[CGPoint]] = lock.withLock {
            if let c = cachedQuads { return c }
            let q = pageRef.map { PDFImageFinder.imageQuads(in: $0) } ?? []
            cachedQuads = q
            return q
        }
        guard !raw.isEmpty else { return [] }
        // PDF user space → the box's space (PDFKit handles /Rotate and the box
        // origin through this transform).
        let t = transform(for: box)
        let pageArea = bounds(for: box).width * bounds(for: box).height
        return raw.compactMap { quad in
            let mapped = quad.map { $0.applying(t) }
            // A picture covering (nearly) the whole page IS the page (scanned
            // documents): invert it like text so scans read dark too.
            let area = abs(PDFImageFinder.polygonArea(mapped))
            return area >= pageArea * 0.85 ? nil : mapped
        }
    }
}

// MARK: - Content-stream scan for image placements

/// Walks a page's content stream (and the Form XObjects it draws) with
/// `CGPDFScanner`, tracking the CTM through `q` / `Q` / `cm`, and records the
/// unit square of every Image XObject painted with `Do` as a quad in PDF user
/// space. Inline images (`BI … EI`) and stencil masks (`ImageMask true`,
/// which are painted in the fill colour like glyphs) are ignored.
enum PDFImageFinder {
    private final class State {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var quads: [[CGPoint]] = []
        var depth = 0
        var budget = 2_000              // form XObjects visited, recursion bombs bounded
    }

    static func imageQuads(in page: CGPDFPage) -> [[CGPoint]] {
        let state = State()
        let cs = CGPDFContentStreamCreateWithPage(page)
        scan(contentStream: cs, state: state)
        return state.quads
    }

    private static let table: CGPDFOperatorTableRef = {
        let t = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(t, "q") { scanner, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            s.stack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "Q") { scanner, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            if let last = s.stack.popLast() { s.ctm = last }
        }
        CGPDFOperatorTableSetCallback(t, "cm") { scanner, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in stride(from: 5, through: 0, by: -1) { CGPDFScannerPopNumber(scanner, &v[i]) }
            let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            s.ctm = m.concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(t, "Do") { scanner, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var cname: UnsafePointer<CChar>? = nil
            guard CGPDFScannerPopName(scanner, &cname), let cname else { return }
            let cs = CGPDFScannerGetContentStream(scanner)
            guard let obj = CGPDFContentStreamGetResource(cs, "XObject", cname) else { return }
            var stream: CGPDFStreamRef? = nil
            guard CGPDFObjectGetValue(obj, .stream, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>? = nil
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                var isMask: CGPDFBoolean = 0
                if CGPDFDictionaryGetBoolean(dict, "ImageMask", &isMask), isMask != 0 { return }
                let unit = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
                s.quads.append(unit.map { $0.applying(s.ctm) })
            case "Form":
                guard s.depth < 12, s.budget > 0 else { return }
                s.budget -= 1
                let saved = s.ctm, savedStack = s.stack
                var matrix: CGPDFArrayRef? = nil
                if CGPDFDictionaryGetArray(dict, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(matrix, i, &v[i]) }
                    s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
                }
                var resources: CGPDFDictionaryRef? = nil
                _ = CGPDFDictionaryGetDictionary(dict, "Resources", &resources)
                // No /Resources (inherits): hand the stream dict, which has no
                // XObject entry, so lookups fall through to the parent stream.
                let inner = CGPDFContentStreamCreateWithStream(stream, resources ?? dict, cs)
                s.depth += 1
                scan(contentStream: inner, state: s)
                s.depth -= 1
                s.ctm = saved; s.stack = savedStack
            default:
                return
            }
        }
        return t
    }()

    private static func scan(contentStream: CGPDFContentStreamRef, state: State) {
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(contentStream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(contentStream)
    }

    /// Shoelace area of a polygon (signed).
    static func polygonArea(_ p: [CGPoint]) -> CGFloat {
        guard p.count >= 3 else { return 0 }
        var a: CGFloat = 0
        for i in p.indices { let j = (i + 1) % p.count; a += p[i].x * p[j].y - p[j].x * p[i].y }
        return a / 2
    }
}
