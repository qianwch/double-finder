import AppKit
import Quartz
import DoubleFinderPluginKit

/// TC's Quick View (Ctrl+Q): overlays the inactive panel with a live preview
/// of the active panel's cursor file. Plugins come first, so the pane shows
/// exactly what F3's Plugin segment shows: a view plugin that claims the file
/// (the built-in PDF viewer, a bundle's WLX-style viewer) is mounted as is; a
/// page plugin (Markdown preview, the EPUB / Kindle reader) is rendered on a
/// background task into a `ListerWebView`, cancelled the moment the cursor
/// moves on. Plain text uses ListerTextView; everything else goes to
/// QLPreviewView (same engine as the
/// Space-bar Quick Look).
final class QuickViewPane: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let preview = QLPreviewView(frame: .zero, style: .normal)!
    private let emptyLabel = NSTextField(labelWithString: "")
    private var pluginView: NSView?
    private let zoomControls = NSStackView()
    private var zoomButtons: [NSButton] = []
    private var webZoom: CGFloat = 1

    // Page plugins (PageViewerPlugin → ListerWebView), same protocol as the Lister:
    // a CancelFlag the plugin polls + a generation stamp so a late result for a
    // file the cursor already left is dropped.
    private var webView: ListerWebView?
    private var webTask: Task<Void, Never>?
    private var webCancel: CancelFlag?
    private var webGeneration = 0
    private var loadingDelay: Task<Void, Never>?
    private var currentPage: (viewer: PageViewerPlugin, url: URL, title: String)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.alignment = .center

        emptyLabel.stringValue = tr("No preview")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        for (label, help, action) in [("−", "Zoom Out", #selector(zoomOut(_:))), ("↺", "Reset Zoom", #selector(resetZoom(_:))), ("+", "Zoom In", #selector(zoomIn(_:)))] {
            let button = NSButton(title: label, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setAccessibilityLabel(tr(help))
            button.toolTip = tr(help)
            zoomControls.addArrangedSubview(button)
            zoomButtons.append(button)
        }
        zoomControls.spacing = 2
        zoomControls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomControls)
        setZoomEnabled(false)
        preview.shouldCloseWithWindow = false

        [titleLabel, preview, emptyLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
            // The preview's intrinsic size must never push the split divider —
            // the pane adopts whatever width the host panel has.
            $0.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            $0.setContentCompressionResistancePriority(.init(1), for: .vertical)
            $0.setContentHuggingPriority(.init(1), for: .horizontal)
            $0.setContentHuggingPriority(.init(1), for: .vertical)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: zoomControls.leadingAnchor, constant: -8),
            zoomControls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            zoomControls.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            titleLabel.heightAnchor.constraint(greaterThanOrEqualTo: zoomControls.heightAnchor),

            preview.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The pane is display-only: keyboard focus must stay on the active file
    /// list so Tab / arrows / F-keys keep working while Quick View is up.
    override var acceptsFirstResponder: Bool { false }

    // The pane covers the inactive panel's file list, but AppKit still routes
    // any mouse event a mounted view leaves unhandled up the responder chain
    // (NSImageView in the image viewer, QL's remote view, an NSScrollView that
    // can't scroll further, …), and from there it lands in the covered list:
    // a click in the preview then moved that list's cursor, activated the
    // hidden panel, and the pane jumped to the other side. The pane is the end
    // of the line for mouse input — swallow everything instead of forwarding.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}

    /// True when the window's first responder is inside this pane —
    /// QLPreviewView's internal remote view grabs focus when a preview loads.
    func holdsKeyboardFocus(in window: NSWindow?) -> Bool {
        guard let fr = window?.firstResponder as? NSView else { return false }
        return fr === self || fr.isDescendant(of: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // Pages whose output bakes the appearance in (Markdown diagrams) ask
        // to be rendered again; CSS-adaptive pages (ebooks) need nothing.
        if let page = currentPage, webView?.isHidden == false,
           webView?.needsMarkdownDiagramRefresh == true || page.viewer.needsRerenderOnAppearanceChange() {
            startPageRender(page.viewer, url: page.url, title: page.title)
        }
    }

    /// nil URL shows the "No preview" placeholder (including pending downloads).
    func show(url: URL?, title: String) {
        titleLabel.stringValue = title
        webZoom = 1
        webView?.setZoom(1)
        setZoomEnabled(false)
        cancelPageRender()
        webGeneration += 1
        currentPage = nil
        unmountPlugin()
        webView?.isHidden = true
        emptyLabel.stringValue = tr("No preview")
        emptyLabel.isHidden = url != nil
        guard let url else { showQuickLook(nil); return }
        let (isFile, sample) = fileSample(url)
        if isFile, let viewer = PluginManager.shared.viewer(for: url, sample: sample) {
            if let view = makePluginView(viewer, url: url) {
                showQuickLook(nil)
                mount(view)
                return
            }
        }
        if isFile, let page = PluginManager.shared.pageViewer(for: url, sample: sample) {
            showQuickLook(nil)
            startPageRender(page, url: url, title: title)
            return
        }
        let routing = ViewerModeChooser.choose(fileExtension: url.pathExtension, sample: sample)
        if isFile, routing.mode == .text, let source = ListerSource(url: url) {
            let text = ListerTextView(frame: .zero)
            text.load(source: source, encoding: routing.encoding ?? .utf8, fileExtension: url.pathExtension)
            showQuickLook(nil)
            mount(text)
            return
        }
        showQuickLook(url)
    }

    func showStatus(_ message: String, title: String) {
        show(url: nil, title: title)
        emptyLabel.stringValue = message
    }

    func showMediaStream(url: URL, title: String) {
        show(url: nil, title: title)
        emptyLabel.isHidden = true
        do { mount(try MediaViewer().makeView(for: url)) }
        catch { showStatus(error.localizedDescription, title: title) }
    }

    private func showQuickLook(_ url: URL?) {
        preview.isHidden = url == nil
        preview.previewItem = url as QLPreviewItem?
    }

    /// (regular file?, first 64 KiB) — what the plugin registry's cheap
    /// `canView` / `canRender` checks are fed. Folders never reach a plugin.
    private func fileSample(_ url: URL) -> (Bool, Data) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return (false, Data()) }
        let sample = (try? FileHandle(forReadingFrom: url)).flatMap { h -> Data? in
            defer { try? h.close() }
            return try? h.read(upToCount: 64 << 10)
        } ?? Data()
        return (true, sample)
    }

    // MARK: View plugins

    /// A plugin whose `makeView` throws falls back the same way as in the Lister.
    private func makePluginView(_ viewer: ViewerPlugin, url: URL) -> NSView? {
        do {
            return try viewer.makeView(for: url)
        } catch {
            NSLog("[plugin] viewer %@ failed for %@: %@", viewer.identifier, url.path, error.localizedDescription)
            return nil
        }
    }

    private func mount(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        pin(view)
        pluginView = view
        setZoomEnabled(view is ListerTextView || ["zoomIn:", "zoomOut:", "resetZoom:"].allSatisfy { view.responds(to: NSSelectorFromString($0)) })
    }

    /// Same rule as the QL view: fill the pane below the title, never push the split divider.
    private func pin(_ view: NSView) {
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .vertical)
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentHuggingPriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func unmountPlugin() {
        pluginView?.removeFromSuperview()
        pluginView = nil
    }

    private func setZoomEnabled(_ enabled: Bool) {
        zoomButtons.forEach { $0.isEnabled = enabled }
    }

    @objc private func zoomIn(_ sender: Any?) { adjustZoom(1) }
    @objc private func zoomOut(_ sender: Any?) { adjustZoom(-1) }
    @objc private func resetZoom(_ sender: Any?) { adjustZoom(0) }

    func adjustZoom(_ step: Int) {
        guard zoomButtons.first?.isEnabled == true else { return }
        if let text = pluginView as? ListerTextView {
            text.setFontSize(step == 0 ? 12 : min(32, max(8, text.fontSize + CGFloat(step))), reapply: true)
        } else if let view = pluginView {
            let selector = NSSelectorFromString(step > 0 ? "zoomIn:" : step < 0 ? "zoomOut:" : "resetZoom:")
            if view.responds(to: selector) { _ = view.perform(selector, with: nil) }
        } else if webView?.isHidden == false {
            webZoom = step == 0 ? 1 : min(3, max(0.5, webZoom + CGFloat(step) * 0.1))
            webView?.setZoom(webZoom)
        }
    }

    // MARK: Page plugins

    private func ensureWebView() -> ListerWebView {
        if let webView { return webView }
        let wv = ListerWebView(frame: .zero)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.onGiveUp = { [weak self] in          // web content process crashed twice
            guard let self, let page = self.currentPage else { return }
            self.pageRenderFailed(PageError("Preview failed"), title: page.title, url: page.url)
        }
        wv.onAppearanceChanged = { [weak self] in
            guard let self, let page = self.currentPage,
                  self.webView?.isHidden == false,
                  self.webView?.needsMarkdownDiagramRefresh == true || page.viewer.needsRerenderOnAppearanceChange() else { return }
            self.startPageRender(page.viewer, url: page.url, title: page.title)
        }
        addSubview(wv)
        pin(wv)
        webView = wv
        return wv
    }

    /// Runs `renderPage` on a detached task; the result (and any later `update`
    /// from the plugin) loads into the web view while the file is still the
    /// one under the cursor. "Loading…" appears only if the render outlasts a
    /// 250ms grace, so small files never flash it.
    private func startPageRender(_ viewer: PageViewerPlugin, url: URL, title: String) {
        cancelPageRender()
        webGeneration += 1
        let gen = webGeneration
        let cancel = CancelFlag()
        webCancel = cancel
        currentPage = (viewer, url, title)
        let wv = ensureWebView()
        wv.showsMarkdownAppearance = viewer is MarkdownPageViewer
        wv.isHidden = true
        wv.loadHTML("")                         // never show the previous file's page under the new title
        loadingDelay = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, self.webGeneration == gen else { return }
            self.emptyLabel.stringValue = tr("Loading…")
            self.emptyLabel.isHidden = false
        }
        let deliver: @Sendable (Result<String, Error>) -> Void = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !cancel.isCancelled, self.webGeneration == gen else { return }
                self.finishPageRender(result, title: title, url: url)
            }
        }
        webTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try viewer.renderPage(url: url, isCancelled: { cancel.isCancelled }, update: deliver))
            } catch is CancellationError {
                return
            } catch {
                result = .failure(error)
            }
            guard !cancel.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, !cancel.isCancelled, self.webGeneration == gen else { return }
                self.webTask = nil
                self.finishPageRender(result, title: title, url: url)
            }
        }
    }

    private func finishPageRender(_ result: Result<String, Error>, title: String, url: URL) {
        loadingDelay?.cancel(); loadingDelay = nil
        emptyLabel.isHidden = true
        switch result {
        case .success(let html):
            webView?.loadHTML(html)
            webView?.isHidden = false
            setZoomEnabled(true)
        case .failure(let error):
            pageRenderFailed(error, title: title, url: url)
        }
    }

    /// The page plugin gave up (DRM, KFX, corrupt, too large): say why in the
    /// title line and let Quick Look have the file (an EPUB still gets its cover).
    private func pageRenderFailed(_ error: Error, title: String, url: URL) {
        cancelPageRender()
        currentPage = nil
        setZoomEnabled(false)
        webView?.isHidden = true
        titleLabel.stringValue = "\(title) — \(tr(error.localizedDescription))"   // built-ins throw English source strings
        showQuickLook(url)
    }

    private func cancelPageRender() {
        loadingDelay?.cancel(); loadingDelay = nil
        webCancel?.cancel(); webCancel = nil
        webTask?.cancel(); webTask = nil
    }

    /// Tear down the QL / web machinery before removing the pane.
    func shutDown() {
        cancelPageRender()
        currentPage = nil
        unmountPlugin()
        webView?.teardown()
        webView?.removeFromSuperview()
        webView = nil
        preview.previewItem = nil
        preview.close()
    }
}
