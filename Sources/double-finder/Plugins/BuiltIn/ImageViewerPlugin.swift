import AppKit
import ImageIO
import DoubleFinderPluginKit

/// Built-in view plugin: images under F3's Plugin segment and in the Quick View
/// pane, with zoom and pan — which Quick Look's preview never offered. Decoding
/// goes through Image I/O, so everything macOS itself can read is in: the usual
/// bitmaps, HEIC / AVIF / WebP, PSD, and camera RAW (Canon CR2 / CR3, Nikon
/// NEF, Sony ARW, Adobe DNG, Fujifilm RAF, Olympus ORF, Panasonic RW2, Pentax
/// PEF…). Animated GIF / APNG / WebP keep animating, SVG stays vector. The
/// image opens fitted to the view; ⌘= / ⌘- zoom in steps, ⌘0 fits again,
/// double-click toggles fit ↔ 100 %, pinch and scroll do what they do
/// everywhere. Quick Look (Preview, 3) stays available.
final class ImageViewerPlugin: NSObject, DFPlugin {
    static let identifier = "net.qian.double-finder.image"

    var info: PluginInfo {
        MainActor.assumeIsolated { PluginInfo(identifier: Self.identifier, name: tr("Image Viewer"), version: "1.0",
                   summary: tr("Shows images in the Lister with zoom and pan, camera RAW (CR2 / NEF / ARW / DNG…) included"),
                   author: "Double Finder") }
    }

    private let viewer = ImageFileViewer()

    override init() { super.init() }

    func activate(host: PluginHost) throws {}

    var viewers: [ViewerPlugin] { [viewer] }
}

final class ImageFileViewer: ViewerPlugin, Sendable {
    let identifier = "image"
    var displayName: String { MainActor.assumeIsolated { tr("Image Viewer") } }

    static let bitmapExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "jfif", "gif", "bmp", "tif", "tiff", "heic", "heif", "heics", "avif", "webp",
        "svg", "icns", "ico", "psd", "jp2", "j2k", "jpf", "jpx", "exr", "hdr", "tga", "pic", "pct", "pict", "qtif", "sgi",
    ]
    /// Camera RAW — Image I/O carries the decoders (the same ones Preview and
    /// Photos use), so no third-party library is involved.
    static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "dng", "raf", "orf", "rw2", "pef", "srw",
        "3fr", "fff", "erf", "kdc", "dcr", "mef", "mos", "mrw", "x3f", "raw", "rwl", "iiq",
    ]

    func canView(url: URL, sample: Data) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.bitmapExtensions.contains(ext) || Self.rawExtensions.contains(ext)
    }

    @MainActor func makeView(for url: URL) throws -> NSView {
        // Cheap header check now, so a file macOS cannot read falls back to the
        // built-in modes the way the Lister expects (throwing here), instead of
        // an empty view: SVG is not an Image I/O type and goes through NSImage.
        let ext = url.pathExtension.lowercased()
        if ext != "svg" {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
                throw PageError("Cannot open image")
            }
        }
        return ImageViewerContainer(url: url)
    }
}

// MARK: - Zoom arithmetic (pure, unit-tested)

enum ImageZoom {
    static let minimum: CGFloat = 0.02
    static let maximum: CGFloat = 64
    static let step: CGFloat = 1.25

    /// Magnification that shows the whole image with a little breathing room,
    /// never enlarging a small image past 100 % (Preview's behaviour).
    static func fit(image: CGSize, in viewport: CGSize, padding: CGFloat = 16) -> CGFloat {
        guard image.width > 0, image.height > 0 else { return 1 }
        let w = max(1, viewport.width - padding * 2), h = max(1, viewport.height - padding * 2)
        return min(1, min(w / image.width, h / image.height))
    }

    /// One ⌘= / ⌘- step from `current`, clamped; the result is rounded so a
    /// run of steps lands on tidy values (…, 64 %, 80 %, 100 %, 125 %, …).
    static func stepped(_ current: CGFloat, direction: Int) -> CGFloat {
        let raw = direction > 0 ? current * step : current / step
        let snapped = (raw * 1000).rounded() / 1000
        return min(maximum, max(minimum, snapped))
    }
}

// MARK: - Decoding (off the main thread)

enum ImageDecoder {
    /// Full-size, orientation-corrected bitmap. RAW goes through Image I/O's
    /// RAW pipeline (a second or two for a 20-megapixel file).
    static func decodeFull(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,        // applies EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Quick first frame: the embedded preview a RAW / JPEG carries, capped at
    /// `maxPixels`, so something appears in tens of milliseconds while the full
    /// decode runs.
    static func decodeQuick(_ url: URL, maxPixels: Int = 2048) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel size after orientation, from the header alone.
    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Animated containers are shown through NSImage so the frames keep playing.
    static func isAnimated(_ url: URL) -> Bool {
        guard ["gif", "png", "webp", "heics"].contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetCount(source) > 1
    }
}

// MARK: - View

/// NSScrollView with magnification around a centred image view, plus a small
/// size / zoom readout. Zoom actions carry the selector names the Lister
/// forwards for ⌘= / ⌘- / ⌘0 to a plugin view.
final class ImageViewerContainer: NSView {
    private let url: URL
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()
    private let readout = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var pixelSize = CGSize.zero
    private var fitMode = true
    private var decodeTask: Task<Void, Never>?
    private var loaded = false

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = ImageZoom.minimum
        scrollView.maxMagnification = ImageZoom.maximum
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently     // the frame IS the pixel size; the scroll view scales
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.isEditable = false
        imageView.wantsLayer = true
        imageView.layer?.magnificationFilter = .linear
        addSubview(scrollView)

        readout.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        readout.textColor = .white
        readout.wantsLayer = true
        readout.layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
        readout.layer?.cornerRadius = 5
        readout.alignment = .center
        readout.isHidden = true
        addSubview(readout)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(userStartedMagnifying),
                                               name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(magnificationChanged),
                                               name: NSView.boundsDidChangeNotification, object: clip)
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        dbl.numberOfClicksRequired = 2
        scrollView.contentView.addGestureRecognizer(dbl)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { window?.makeFirstResponder(scrollView.contentView) ?? false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { decodeTask?.cancel(); decodeTask = nil } else if !loaded { loaded = true; load() }
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        readout.sizeToFit()
        readout.frame = NSRect(x: 10, y: 10, width: readout.frame.width + 14, height: 20)
        spinner.frame = NSRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
        if fitMode, pixelSize != .zero { applyFit() }
    }

    // MARK: Loading

    private func load() {
        let url = self.url
        if url.pathExtension.lowercased() == "svg" || ImageDecoder.isAnimated(url) {
            // Vector / animated: NSImage keeps the vector data or the frames.
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return }
            show(image, pixels: image.size)
            return
        }
        spinner.startAnimation(nil)
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Stage 1: the embedded preview (fast) …
            if let quick = ImageDecoder.decodeQuick(url), !Task.isCancelled {
                let size = ImageDecoder.pixelSize(url) ?? CGSize(width: quick.width, height: quick.height)
                await MainActor.run { [weak self] in
                    self?.show(NSImage(cgImage: quick, size: size), pixels: size)   // drawn at the real size
                }
            }
            guard !Task.isCancelled else { return }
            // … stage 2: the full bitmap (the RAW pipeline for RAW).
            if let full = ImageDecoder.decodeFull(url), !Task.isCancelled {
                let size = CGSize(width: full.width, height: full.height)
                await MainActor.run { [weak self] in
                    self?.show(NSImage(cgImage: full, size: size), pixels: size)
                }
            }
            await MainActor.run { [weak self] in self?.spinner.stopAnimation(nil) }
        }
    }

    private func show(_ image: NSImage, pixels: CGSize) {
        let first = pixelSize == .zero
        pixelSize = pixels
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: pixels)
        if first { fitMode = true; applyFit() } else { updateReadout() }
        readout.isHidden = false
    }

    // MARK: Zoom

    private func applyFit() {
        // contentSize is the viewport in points; the clip view's *bounds* are in
        // document units and grow as magnification shrinks, so measuring with
        // them re-fits to "100 %" after the first fit (2026-09-13).
        let viewport = scrollView.contentSize
        guard viewport.width > 0, viewport.height > 0 else { return }
        let m = ImageZoom.fit(image: pixelSize, in: viewport)
        scrollView.setMagnification(m, centeredAt: NSPoint(x: pixelSize.width / 2, y: pixelSize.height / 2))
        updateReadout()
    }

    private func zoom(to m: CGFloat) {
        fitMode = false
        let visible = scrollView.contentView.bounds
        scrollView.setMagnification(m, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        updateReadout()
    }

    @objc func zoomIn(_ sender: Any?) { zoom(to: ImageZoom.stepped(scrollView.magnification, direction: +1)) }
    @objc func zoomOut(_ sender: Any?) { zoom(to: ImageZoom.stepped(scrollView.magnification, direction: -1)) }
    @objc func resetZoom(_ sender: Any?) { fitMode = true; applyFit() }

    @objc private func doubleClicked() {
        // Fit ↔ 100 %; at 100 % already (small image) go to fit anyway.
        if fitMode && scrollView.magnification < 0.999 { zoom(to: 1) } else { resetZoom(nil) }
    }

    @objc private func magnificationChanged() { updateReadout() }
    @objc private func userStartedMagnifying() { fitMode = false }     // pinch → no longer "fit"

    private func updateReadout() {
        guard pixelSize != .zero else { return }
        let pct = Int((scrollView.magnification * 100).rounded())
        readout.stringValue = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))  ·  \(pct)%"
        needsLayout = true
    }
}

/// Keeps a document smaller than the viewport centred instead of pinned to a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return r }
        let docFrame = doc.frame
        if r.width > docFrame.width { r.origin.x = docFrame.midX - r.width / 2 }
        if r.height > docFrame.height { r.origin.y = docFrame.midY - r.height / 2 }
        return r
    }
}
