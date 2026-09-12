import AppKit
import DoubleFinderPluginKit
import QuickLookUI

// MARK: - Pure navigation logic (unit-tested in InternalViewerNavTests)

enum ViewerNavDirection { case prev, next }

/// Next index when stepping through a list. Clamps to `[0, count-1]` (no wraparound);
/// returns 0 for an empty list.
func nextIndex(current: Int, count: Int, direction: ViewerNavDirection) -> Int {
    guard count > 0 else { return 0 }
    switch direction {
    case .prev: return max(0, current - 1)
    case .next: return min(count - 1, current + 1)
    }
}

// MARK: - ViewerEntry

/// One previewable item, decoupled from its source. `resolve` materializes it to a
/// local file URL on demand: local = identity, remote (SFTP/S3/archive) = download/extract.
/// Returning nil means the item could not be fetched.
struct ViewerEntry {
    let title: String
    let resolve: () async -> URL?
}

// MARK: - InternalViewerController

/// Three-mode Lister window: Text (chunked NSTextView) / Hexadecimal (owner-drawn
/// dump) / Preview (embedded `QLPreviewView`) in our OWN window. The mode is
/// auto-chosen per file (ViewerModeChooser) and manually switchable via the
/// titlebar segments or the 1/2/3 keys. ⌘-arrows step file-to-file, ⌘F opens the
/// dual-mode find bar (string / hex bytes), Esc closes the bar then the window.
/// Items are loaded lazily one at a time, so opening a huge folder stays instant
/// and remote items download on demand.
@MainActor
final class InternalViewerController: NSObject, NSWindowDelegate {
    static let shared = InternalViewerController()

    private var entries: [ViewerEntry] = []
    private var currentIndex = 0
    private var onIndexChange: ((Int) -> Void)?
    private var navGeneration = 0

    private var window: NSWindow?
    private var monitor: Any?

    // Window chrome (all torn down exhaustively in windowWillClose)
    private var container: NSView?                    // content area (above statusBar)
    private var modeControl: NSSegmentedControl?      // titlebar accessory: Text/Hexadecimal/Preview[/Plugin]
    private var titlebarAccessory: NSTitlebarAccessoryViewController?
    private var textContent: ListerTextView?          // lazy
    private var hexScroll: NSScrollView?              // lazy, documentView = hexView
    private var hexView: ListerHexView?
    private var previewView: QLPreviewView?           // lazy (was eagerly built pre-Lister)
    private var mdWebView: ListerWebView?             // lazy, a page viewer's rendered page (Plugin segment)
    private var pluginView: NSView?                   // a ViewerPlugin's view for the current file
    /// The view plugin claiming the current file (nil = none; segment 4 then depends on `pageViewer`).
    private var pluginViewer: ViewerPlugin?
    /// Built-in mode the chooser picked for the current file — the fallback when
    /// a plugin view can't be built or a page render fails (`.md` → text
    /// source, `.epub` → Quick Look, `.mobi` → hex), and what 1/2/3 return to.
    private var builtInChoice: ViewerMode = .preview
    private var statusBar: NSStackView?               // bottom bar
    private var encodingPopup: NSPopUpButton?
    private var wrapCheck: NSButton?
    private var positionLabel: NSTextField?
    private var statusNote: NSTextField?              // cap/auto-switch notes, cleared after a few seconds
    private var searchBar: ListerSearchBar?           // lazy, pinned to the content view's top
    private var searchBarVisible = false
    private var containerTopConstraint: NSLayoutConstraint?
    private var noteGeneration = 0

    // Per-file state
    private var currentMode: ViewerMode = .preview
    private var source: ListerSource?
    private var currentURL: URL?
    private var currentEncoding: String.Encoding = .utf8
    /// The `PageViewerPlugin` (built-in Markdown / ebook, or a bundle's) that
    /// claimed the current file — the Plugin segment (4) then shows its rendered
    /// page in `mdWebView`. nil when no page viewer claims the file, or when a
    /// `ViewerPlugin` (own NSView) claims it too — the view plugin wins.
    private var pageViewer: PageViewerPlugin?
    /// Set ONLY when a crashed WKWebView gives up twice (design §4.1) — makes
    /// showWeb false so preview stays on the fall-back. Reset per-file in load().
    private var webCrashed = false
    /// Set when the page viewer threw (too large / DRM / read error): the file
    /// shows in the chooser's mode instead until the user presses 4 again, which
    /// clears it and re-attempts the render (design §4.1 semantics kept).
    private var pageFellBack = false
    /// In-flight background page render (`PageViewerPlugin.renderPage` on a
    /// detached task so a multi-MB file never freezes the window). Cancelled by
    /// any mode switch, file change or close through `pageCancel`; completion
    /// is additionally gated on `pageGeneration` so a late result — or a late
    /// phase-2 `update` from the plugin — can never land on another page.
    private var webRenderTask: Task<Void, Never>?
    private var pageCancel: CancelFlag?
    /// Bumped on every setMode/close — the generation token above.
    private var pageGeneration = 0

    // Zoom (⌘= / ⌘- / ⌘0). Deliberately NOT reset in windowWillClose — the
    // singleton keeps the user's chosen size for the next viewer session.
    // Text & hex share one monospaced font size; rendered markdown zooms the
    // whole page; QL preview has no zoom.
    private var listerFontSize: CGFloat = 12
    private var webZoom: CGFloat = 1

    // Search state (one ListerSearch instance per file+pattern+encoding+case key)
    private var search: ListerSearch?
    private var searchTask: Task<Void, Never>?
    private var lastMatch: (offset: UInt64, length: Int)?
    // True for the duration of an in-flight forward scan. Guards every synchronous,
    // main-actor read of `search!.matches` (Find Previous, and `validateQuery`'s
    // re-enabling of ‹/›) against the detached scan task concurrently appending to
    // that same array — `ListerSearch` is only safe under single-task exclusivity.
    private var searchBusy = false

    // Loading indicator. A remote download — or one entry out of a SOLID 7z, which
    // costs a decompression pass over the archive — can take tens of seconds; before
    // this the window just sat there blank with no sign it was working.
    private var loadingOverlay: AppearanceAwareView?
    private var loadingSpinner: NSProgressIndicator?
    /// The in-flight `entry.resolve()`. Cancelled when the user steps to another file
    /// or closes the window, which propagates into the extract/download itself.
    private var resolveTask: Task<Void, Never>?
    /// Delays the overlay so instant (local) files don't flash a spinner.
    private var spinnerDelayTask: Task<Void, Never>?

    private override init() { super.init() }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Show `entries`, opening on `start`. If already visible, reuses the window and
    /// replaces the list in place. `onIndexChange` fires whenever the shown item changes
    /// (nil for sources without a panel cursor, e.g. search results).
    func show(entries: [ViewerEntry], start: Int, onIndexChange: ((Int) -> Void)?) {
        guard !entries.isEmpty else { NSSound.beep(); return }
        self.entries = entries
        self.onIndexChange = onIndexChange
        let startIdx = max(0, min(start, entries.count - 1))

        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        load(startIdx)
    }

    func close() { window?.performClose(nil) }

    // MARK: Window

    private func buildWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.delegate = self
        w.isReleasedWhenClosed = false
        guard let contentView = w.contentView else { return }

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(box)

        // Bottom status bar: encoding popup + wrap checkbox (text mode), a
        // transient note in the middle, position/percent on the right.
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        for c in EncodingDetector.candidates { popup.addItem(withTitle: c.label) }
        popup.target = self
        popup.action = #selector(encodingChanged(_:))

        let wrap = NSButton(checkboxWithTitle: tr("Wrap lines"),
                            target: self, action: #selector(wrapToggled(_:)))
        wrap.controlSize = .small
        wrap.font = .systemFont(ofSize: 11)
        wrap.state = .on

        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentHuggingPriority(.defaultLow, for: .horizontal)
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let pos = NSTextField(labelWithString: "")
        pos.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        pos.textColor = .secondaryLabelColor
        pos.alignment = .right

        let status = NSStackView(views: [popup, wrap, note, pos])
        status.orientation = .horizontal
        status.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        status.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(status)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24),
        ])

        // Titlebar accessory: mode segments on the right of the title bar.
        let seg = NSSegmentedControl(labels: [tr("Text"), tr("Hexadecimal"), tr("Preview"), tr("Plugin")],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged(_:)))
        seg.segmentCount = 3                          // the Plugin segment appears per file (updatePluginSegment)
        seg.controlSize = .small
        seg.sizeToFit()
        let holder = NSView(frame: NSRect(x: 0, y: 0,
                                          width: seg.frame.width + 12,
                                          height: seg.frame.height + 6))
        seg.setFrameOrigin(NSPoint(x: 6, y: 3))
        holder.addSubview(seg)
        let acc = NSTitlebarAccessoryViewController()
        acc.view = holder
        acc.layoutAttribute = .right
        w.addTitlebarAccessoryViewController(acc)

        w.center()
        self.window = w
        self.container = box
        self.statusBar = status
        self.encodingPopup = popup
        self.wrapCheck = wrap
        self.statusNote = note
        self.positionLabel = pos
        self.modeControl = seg
        self.titlebarAccessory = acc
        layoutContent()
        installMonitor()
    }

    /// Shows the 4th segment ("Plugin") only while a plugin — view or page —
    /// claims the current file; a permanently greyed segment on every other
    /// file was just noise. The accessory grows/shrinks with it.
    private func updatePluginSegment(visible: Bool) {
        guard let seg = modeControl else { return }
        let want = visible ? 4 : 3
        guard seg.segmentCount != want else { return }
        seg.segmentCount = want
        if visible {
            seg.setLabel(tr("Plugin"), forSegment: 3)
            seg.setEnabled(true, forSegment: 3)
        }
        seg.sizeToFit()
        titlebarAccessory?.view.frame.size.width = seg.frame.width + 12
    }

    /// Re-pin the content area's top edge: below the search bar when visible,
    /// at the content view's top otherwise.
    private func layoutContent() {
        guard let container, let contentView = window?.contentView else { return }
        containerTopConstraint?.isActive = false
        if searchBarVisible, let bar = searchBar {
            containerTopConstraint = container.topAnchor.constraint(equalTo: bar.bottomAnchor)
        } else {
            containerTopConstraint = container.topAnchor.constraint(equalTo: contentView.topAnchor)
        }
        containerTopConstraint?.isActive = true
    }

    /// True when the Plugin segment shows a page viewer's rendered page
    /// (ListerWebView): a page viewer claimed the file, the web view has not
    /// given up (crash) and the last render did not fail. Preview (3) is always
    /// Quick Look.
    private func shouldShowWeb() -> Bool {
        currentMode == .plugin && pageViewer != nil && !webCrashed && !pageFellBack
    }

    /// Lazily build the current mode's view inside `container`, hide the others.
    /// Preview mode routes to either the rendered-markdown web view or QL.
    private func showOnlyCurrentModeView() {
        guard let container else { return }
        let showWeb = shouldShowWeb()
        switch currentMode {
        case .text:
            if textContent == nil {
                let tv = ListerTextView(frame: container.bounds)
                tv.autoresizingMask = [.width, .height]
                tv.setFontSize(listerFontSize, reapply: false)
                wireTextCallbacks(tv)
                container.addSubview(tv)
                textContent = tv
            }
        case .hex:
            if hexView == nil {
                let hv = ListerHexView()
                hv.setFontSize(listerFontSize, reapply: false)
                wireHexCallbacks(hv)
                let sc = NSScrollView(frame: container.bounds)
                sc.autoresizingMask = [.width, .height]
                sc.hasVerticalScroller = true
                sc.hasHorizontalScroller = true
                sc.documentView = hv
                sc.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self, selector: #selector(hexClipBoundsChanged),
                    name: NSView.boundsDidChangeNotification, object: sc.contentView)
                container.addSubview(sc)
                hexScroll = sc
                hexView = hv
            }
        case .plugin:
            // A view plugin's NSView is built (or refused) in setMode →
            // mountPluginView; a page viewer renders into the shared web view.
            if showWeb, mdWebView == nil {
                let wv = ListerWebView(frame: container.bounds)
                wv.autoresizingMask = [.width, .height]
                wv.setZoom(webZoom)
                wv.onGiveUp = { [weak self] in
                    guard let self else { return }
                    self.webCrashed = true
                    self.setMode(self.builtInChoice, auto: true)
                    self.showStatusNote(tr("Plugin viewer failed — showing built-in view"))
                }
                wv.onAppearanceChanged = { [weak self] in self?.appearanceChangedInPreview() }
                container.addSubview(wv)
                mdWebView = wv
            }
        case .preview:
            if previewView == nil {
                let pv = QLPreviewView(frame: container.bounds, style: .normal)!
                pv.autoresizingMask = [.width, .height]
                pv.shouldCloseWithWindow = true
                pv.autostarts = true
                container.addSubview(pv)
                previewView = pv
            }
        }
        textContent?.isHidden = currentMode != .text
        hexScroll?.isHidden = currentMode != .hex
        previewView?.isHidden = currentMode != .preview
        mdWebView?.isHidden = !showWeb
        pluginView?.isHidden = !(currentMode == .plugin && !showWeb)
        if showWeb {
            previewView?.previewItem = nil              // free QL, hand focus to web
            mdWebView?.focus()
        } else {
            mdWebView?.loadHTML("")                      // drop any stale rendered page
        }
    }

    private func wireTextCallbacks(_ tv: ListerTextView) {
        tv.onStatusChange = { [weak self] in self?.updatePositionLabel() }
        tv.onCapReached = { [weak self] in
            self?.showStatusNote(tr("Reached text-mode load limit — use Hexadecimal (2) for deeper content"))
            NSSound.beep()
        }
        tv.onReadError = { [weak self] in
            self?.showStatusNote(tr("Read error — cannot access the file")); NSSound.beep()
        }
        tv.onDecodeFallback = { [weak self] in
            // The callback fires synchronously from inside load()/appendChunk —
            // the reload must be deferred past the current loading loop, or the
            // re-entrant load() resets state under the outer loop's feet.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentEncoding != .isoLatin1, let source = self.source else { return }
                // State consistency: reload wholesale as ISO-8859-1 so the popup,
                // currentEncoding and the visible text agree. The guard prevents
                // re-entry (a Latin-1 reload never falls back again).
                self.currentEncoding = .isoLatin1
                let anchor = self.textContent?.topVisibleByteOffset() ?? 0
                self.textContent?.load(source: source, encoding: .isoLatin1, anchorByte: anchor,
                                       fileExtension: self.currentURL?.pathExtension)
                self.selectEncodingInPopup(.isoLatin1)
                self.showStatusNote(tr("Decoding failed — showing as ISO-8859-1"))
            }
        }
    }

    private func wireHexCallbacks(_ hv: ListerHexView) {
        hv.onStatusChange = { [weak self] in self?.updatePositionLabel() }
        hv.onReadError = { [weak self] in
            self?.showStatusNote(tr("Read error — cannot access the file")); NSSound.beep()
        }
    }

    @objc private func hexClipBoundsChanged() { updatePositionLabel() }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let modes: [ViewerMode] = [.text, .hex, .preview, .plugin]
        guard modes.indices.contains(sender.selectedSegment) else { return }
        setMode(modes[sender.selectedSegment], auto: false)
    }

    @objc private func wrapToggled(_ sender: NSButton) {
        textContent?.wrapsLines = (sender.state == .on)
    }

    /// ⌘= / ⌘- / ⌘0 → step +1 / -1 / reset. Text & hex share one font size
    /// (8–32pt, reset 12); only the ACTIVE view restyles in place — the hidden
    /// sibling just records the size, its content is reloaded on every mode
    /// switch anyway. Markdown preview zooms the page (50–300%, reset 100%);
    /// QL preview has nothing to zoom.
    private func adjustZoom(_ step: Int) {
        switch currentMode {
        case .text, .hex:
            let size = step == 0 ? 12 : min(32, max(8, listerFontSize + CGFloat(step)))
            guard size != listerFontSize else { return }
            listerFontSize = size
            textContent?.setFontSize(size, reapply: currentMode == .text)
            hexView?.setFontSize(size, reapply: currentMode == .hex)
        case .preview:
            NSSound.beep()                      // Quick Look has nothing to zoom
        case .plugin:
            guard shouldShowWeb() else { NSSound.beep(); return }   // a plugin VIEW zooms (or not) on its own
            let zoom = step == 0 ? 1 : min(3, max(0.5, webZoom + CGFloat(step) * 0.1))
            guard zoom != webZoom else { return }
            webZoom = zoom
            mdWebView?.setZoom(zoom)
        }
    }

    // MARK: Key monitor

    /// Window-scoped key monitor: only acts on our window, BEFORE the responder
    /// chain. ⌘-arrows step file-to-file; 1/2/3 switch modes; ⌘F finds; Esc
    /// closes the find bar then the window. Bare arrows/PgUp/PgDn/Home/space
    /// fall through to the content view (scrolling; QL pauses videos on space).
    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let cmd = event.modifierFlags.contains(.command)
            if self.isSearchFieldFocused {                      // find field gets right of way
                switch event.keyCode {
                case 53: self.closeSearchBar(); return nil      // Esc
                case 36, 76:                                    // Enter / keypad-Enter
                    self.find(backwards: event.modifierFlags.contains(.shift)); return nil
                default: return event                           // everything else → the field
                }
            }
            if cmd {
                switch event.keyCode {
                case 123, 126: self.navigate(.prev); return nil // ⌘← / ⌘↑
                case 124, 125: self.navigate(.next); return nil // ⌘→ / ⌘↓
                default:
                    switch event.charactersIgnoringModifiers {
                    case "f": self.toggleSearchBar(); return nil
                    case "=", "+": self.adjustZoom(+1); return nil   // ⌘= / ⌘⇧= zoom in
                    case "-": self.adjustZoom(-1); return nil        // ⌘- zoom out
                    case "0": self.adjustZoom(0); return nil         // ⌘0 reset
                    default: return event
                    }
                }
            }
            let bare = event.modifierFlags.intersection([.option, .control, .shift]).isEmpty
            switch event.keyCode {
            case 18 where bare: self.setMode(.text, auto: false); return nil     // 1 (not ⌥/⌃ combos)
            case 19 where bare: self.setMode(.hex, auto: false); return nil      // 2
            case 20 where bare: self.setMode(.preview, auto: false); return nil  // 3
            case 21 where bare:                                                  // 4 (plugin, when one applies)
                if self.pluginViewer != nil || self.pageViewer != nil { self.setMode(.plugin, auto: false) } else { NSSound.beep() }
                return nil
            case 119 where self.currentMode == .text:            // End: load to cap/EOF in one go
                self.textContent?.loadToEnd(); return nil
            case 53:                                             // Esc
                if self.searchBarVisible { self.closeSearchBar() } else { self.close() }
                return nil
            case 49 where self.currentMode == .text: self.textContent?.pageDown(); return nil
            case 49 where self.currentMode == .hex: self.hexView?.pageDown(); return nil
            default: return event   // bare arrows/PgUp/PgDn/Home/End/space(QL) → responder chain
            }
        }
    }

    private var isSearchFieldFocused: Bool {
        guard searchBarVisible, let fe = window?.firstResponder as? NSTextView else { return false }
        return fe.delegate === searchBar?.field
    }

    private func navigate(_ dir: ViewerNavDirection) {
        let ni = nextIndex(current: currentIndex, count: entries.count, direction: dir)
        guard ni != currentIndex else { return }
        load(ni)
    }

    // MARK: Per-file loading

    /// Resolve and show item `index`. Remote resolves are async; a generation token
    /// discards stale results when the user keeps stepping through files.
    private func load(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
        navGeneration += 1
        let gen = navGeneration
        let entry = entries[index]; let total = entries.count
        cancelSearch(clearQuery: true)               // new file = new search context
        webCrashed = false                           // per-file: give the next page a fresh render attempt
        pageFellBack = false
        pageGeneration += 1                          // void the previous file's in-flight render / phase 2
                                                     // (design §5.3): it must not land during entry.resolve()
        resolveTask?.cancel()                        // stop the previous file's download/extract
        // Name the INCOMING file right away: during a slow resolve the titlebar
        // would otherwise still advertise the previous one.
        window?.title = "\(entry.title) — (\(index + 1)/\(total))"
        beginLoadingIndicator()
        resolveTask = Task { [weak self] in
            let url = await entry.resolve()
            guard let self, self.navGeneration == gen else { return }
            self.endLoadingIndicator()
            self.pluginViewer = nil
            self.pageViewer = nil
            self.pluginView?.removeFromSuperview(); self.pluginView = nil
            guard let url else {
                self.source = nil; self.currentURL = nil
                self.updatePluginSegment(visible: false)
                self.setMode(.preview, auto: true)
                self.previewView?.previewItem = nil
                self.window?.title = "\(tr("Cannot load")) — (\(index + 1)/\(total))"
                NSSound.beep(); self.onIndexChange?(index); return
            }
            self.currentURL = url
            self.source = ListerSource(url: url)
            let sample = self.source?.read(offset: 0, count: 64 << 10)
            let choice = ViewerModeChooser.choose(fileExtension: url.pathExtension, sample: sample)
            self.currentEncoding = choice.encoding ?? .utf8
            self.builtInChoice = choice.mode
            // A plugin that claims the file wins the auto choice (TC: WLX plugins
            // take precedence over the built-in modes) and lights the Plugin
            // segment: a view plugin first, else a page viewer (built-in
            // Markdown / ebook, or a bundle's). The chooser's verdict stays the
            // fall-back for a failed view / render.
            self.pluginViewer = PluginManager.shared.viewer(for: url, sample: sample ?? Data())
            self.pageViewer = self.pluginViewer == nil
                ? PluginManager.shared.pageViewer(for: url, sample: sample ?? Data()) : nil
            let claimed = self.pluginViewer != nil || self.pageViewer != nil
            self.updatePluginSegment(visible: claimed)
            self.setMode(claimed ? .plugin : choice.mode, auto: true)
            self.window?.title = "\(entry.title) — (\(index + 1)/\(total))"
            self.onIndexChange?(index)
        }
    }

    // MARK: Loading indicator

    /// Arm the spinner. It only appears if the resolve is still running after a
    /// short delay, so local files (resolved instantly) never flash it.
    private func beginLoadingIndicator() {
        spinnerDelayTask?.cancel()
        let gen = navGeneration
        spinnerDelayTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.navGeneration == gen else { return }
            self.showLoadingOverlay()
        }
    }

    private func endLoadingIndicator() {
        spinnerDelayTask?.cancel(); spinnerDelayTask = nil
        loadingSpinner?.stopAnimation(nil)
        loadingOverlay?.removeFromSuperview()
    }

    /// Centered spinner + "Loading…" over the content area, on an opaque backdrop so
    /// the previous file's text isn't mistaken for the incoming one.
    private func showLoadingOverlay() {
        guard let container else { return }
        let overlay: AppearanceAwareView = loadingOverlay ?? {
            let v = AppearanceAwareView()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.backgroundColor = .windowBackgroundColor

            let spin = NSProgressIndicator()
            spin.style = .spinning
            spin.controlSize = .regular
            spin.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: tr("Loading…"))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.alignment = .center

            let hint = NSTextField(labelWithString: tr("Press Esc to cancel"))
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .tertiaryLabelColor
            hint.alignment = .center

            let stack = NSStackView(views: [spin, label, hint])
            stack.orientation = .vertical
            stack.spacing = 8
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            self.loadingOverlay = v
            self.loadingSpinner = spin
            return v
        }()

        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        loadingSpinner?.startAnimation(nil)
    }

    // MARK: Mode switching

    /// Shared by manual 1/2/3 switches and per-file auto routing; `preserveSearch`
    /// is only used by the deep-match auto-switch to hex.
    private func setMode(_ mode: ViewerMode, auto: Bool, preserveSearch: Bool = false) {
        if !preserveSearch, !auto { cancelSearch(clearQuery: true) }   // manual switch clears the search (design §6)
        if mode == .plugin, !auto { pageFellBack = false }            // an explicit 4 re-attempts a failed page render
        pageGeneration += 1                       // leaving/reloading a page voids in-flight render / phase-2 results
        cancelWebRender()                       // …and any render still converting for the previous page
        // Manual same-file switches keep the reading position by byte offset
        // (same anchoring as encoding changes; TC behavior).
        let anchor: UInt64 = (!auto && (mode == .text || mode == .hex)) ? currentTopByteOffset() : 0
        if mode == .plugin, pageViewer == nil, !mountPluginView() {
            // The view plugin refused (threw) or vanished: fall back to the
            // built-in choice for this file and say so.
            pluginViewer = nil
            updatePluginSegment(visible: false)
            setMode(builtInChoice, auto: true, preserveSearch: preserveSearch)
            showStatusNote(tr("Plugin viewer failed — showing built-in view"))
            return
        }
        currentMode = mode
        modeControl?.selectedSegment = [.text: 0, .hex: 1, .preview: 2, .plugin: 3][mode]!
        showOnlyCurrentModeView()
        switch mode {
        case .plugin:
            if shouldShowWeb(), let viewer = pageViewer, let url = currentURL {
                startPageRender(viewer, url: url)
                mdWebView?.focus()
            } else if let pv = pluginView {
                window?.makeFirstResponder(pv)
            }
        case .text:
            if let source {
                textContent?.load(source: source, encoding: currentEncoding, anchorByte: anchor,
                                  fileExtension: currentURL?.pathExtension)
            }
            textContent?.focus()
            // Revealing the text view right after the markdown WKWebView (a
            // layer-backed sibling that forces the whole container subtree
            // layer-backed) leaves the freshly-unhidden view uninvalidated: on
            // the FIRST preview→text switch it would paint blank until the next
            // layout pass. Force one synchronous redraw of the revealed subtree.
            textContent?.display()
        case .hex:
            if let source { hexView?.load(source: source) }
            if anchor > 0 { hexView?.scrollToOffset(anchor) }
            hexView?.focus()
        case .preview:
            previewView?.previewItem = currentURL as NSURL?
            window?.makeFirstResponder(previewView)
        }
        searchBar?.mode = (mode == .hex) ? .hex : .text
        reconfigureStatusBar()
    }

    /// Builds (or rebuilds) the plugin's view for the current file. false when
    /// there is no claiming plugin or it threw.
    private func mountPluginView() -> Bool {
        guard let viewer = pluginViewer, let url = currentURL, let container else { return false }
        pluginView?.removeFromSuperview()
        pluginView = nil
        do {
            let v = try viewer.makeView(for: url)
            v.frame = container.bounds
            v.autoresizingMask = [.width, .height]
            container.addSubview(v)
            pluginView = v
            return true
        } catch {
            NSLog("[plugin] viewer %@ failed for %@: %@", viewer.identifier, url.path, error.localizedDescription)
            return false
        }
    }

    // MARK: Search

    private func toggleSearchBar() {
        guard currentMode != .preview, currentMode != .plugin else { NSSound.beep(); return }  // no byte view to search
        searchBarVisible ? closeSearchBar() : openSearchBar()
    }

    private func openSearchBar() {
        if searchBar == nil, let contentView = window?.contentView {
            let bar = ListerSearchBar()
            bar.onFind = { [weak self] back in self?.find(backwards: back) }
            bar.onClose = { [weak self] in self?.closeSearchBar() }
            bar.onQueryChanged = { [weak self] in self?.validateQuery() }
            bar.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                bar.topAnchor.constraint(equalTo: contentView.topAnchor),
                bar.heightAnchor.constraint(equalToConstant: 32),
            ])
            searchBar = bar
        }
        searchBar?.mode = (currentMode == .hex) ? .hex : .text
        searchBar?.isHidden = false
        searchBarVisible = true
        layoutContent()
        validateQuery()
        searchBar?.focus()
    }

    private func closeSearchBar() {
        searchTask?.cancel()                    // Esc cancels an in-flight scan
        searchBusy = false
        searchBar?.setBusy(false)
        searchBar?.isHidden = true
        searchBarVisible = false
        layoutContent()
        switch currentMode {                    // hand focus back to the content view
        case .text: textContent?.focus()
        case .hex: hexView?.focus()
        case .preview: window?.makeFirstResponder(previewView)
        case .plugin: window?.makeFirstResponder(pluginView)
        }
    }

    /// Instant validation (every keystroke, not just Enter): invalid hex input
    /// turns red and disables ‹/›.
    private func validateQuery() {
        guard let bar = searchBar else { return }
        if bar.mode == .hex {
            let ok = ListerSearch.parseHexPattern(bar.query) != nil
            bar.markInvalid(!bar.query.isEmpty && !ok)
            bar.setFindEnabled(ok && !searchBusy)
        } else {
            bar.markInvalid(false)
            bar.setFindEnabled(!bar.query.isEmpty && !searchBusy)
        }
    }

    /// Search-state reset on file change / encoding change / manual mode switch:
    /// lastMatch goes too.
    private func cancelSearch(clearQuery: Bool) {
        searchTask?.cancel(); searchTask = nil
        search = nil
        lastMatch = nil
        searchBusy = false
        searchBar?.setBusy(false)
        if clearQuery { searchBar?.setQuerySilently("") }   // doesn't fire onQueryChanged…
        validateQuery()                                      // …so re-derive button enablement here
    }

    /// Where find() starts scanning: the top visible byte in the current mode.
    private func currentTopByteOffset() -> UInt64 {
        switch currentMode {
        case .text: return textContent?.topVisibleByteOffset() ?? 0
        case .hex: return hexView?.topVisibleOffset ?? 0
        case .preview, .plugin: return 0
        }
    }

    private func find(backwards: Bool) {
        guard currentMode != .preview, currentMode != .plugin else { NSSound.beep(); return }  // no byte view to search
        guard let source, let bar = searchBar else { return }
        let pattern: [UInt8]
        if bar.mode == .hex {
            guard let p = ListerSearch.parseHexPattern(bar.query) else {
                bar.markInvalid(true); NSSound.beep(); return
            }
            pattern = p
        } else {
            guard let d = bar.query.data(using: currentEncoding), !d.isEmpty else { NSSound.beep(); return }
            pattern = [UInt8](d)
        }
        bar.markInvalid(false)
        var fold = bar.mode == .text && !bar.matchCase
        // Deep-match auto-switch flips the bar to hex while the search context
        // lives on (design §6 exception). In hex mode the Match-case checkbox is
        // hidden, so a recomputed fold=false is a mode artifact — keep the existing
        // instance's folding for the same pattern instead of silently invalidating
        // its match cache (and quietly changing folded → exact matching).
        if bar.mode == .hex, let s = search, s.pattern == pattern { fold = s.foldCase }
        // A backwards step is cache-only and runs synchronously on the main actor,
        // but the detached forward-scan task concurrently appends to the shared
        // match list — refuse BEFORE mutating any search state, so the beep is
        // truly side-effect-free (a mid-scan ⇧Enter with a changed query must not
        // replace the ListerSearch instance the running task is using).
        if backwards, searchBusy { NSSound.beep(); return }
        if search == nil || search!.pattern != pattern || search!.foldCase != fold {
            search = ListerSearch(pattern: pattern, foldCase: fold)  // key changed → fresh instance (= cache invalidation)
            lastMatch = nil
        }
        let from = lastMatch?.offset ?? currentTopByteOffset()
        if backwards {
            if let hit = search!.previousMatch(before: from) { reveal(hit, length: pattern.count) }
            else { NSSound.beep() }
            return
        }
        // Cancellation & mutual exclusion: the detached task IS searchTask —
        // cancel() is what feeds nextMatch's isCancelled probe; and a new task
        // first awaits the old one's corpse, guaranteeing only one task ever
        // touches a given ListerSearch instance (its @unchecked Sendable premise).
        let previous = searchTask
        previous?.cancel()
        searchBusy = true
        bar.setBusy(true)
        let s = search!, len = source.length
        let wasFirstSearch = (lastMatch == nil && from == 0)
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            _ = await previous?.value
            var hit = s.nextMatch(after: from, fileLength: len,
                                  isCancelled: { Task.isCancelled }, read: source.read)
            // nextMatch is strictly-after: a hit at offset 0 only enters the cache,
            // it is never returned. On the first search check the cache head so a
            // match at the very start of the file isn't skipped forever (Task 5
            // review note).
            if wasFirstSearch, s.matches.first == 0 { hit = 0 }
            let found = hit                                // immutable copy for the Sendable hop
            await MainActor.run { [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.searchBusy = false
                self.searchBar?.setBusy(false)
                self.validateQuery()                       // re-derive ‹/› enablement after busy
                if let found { self.reveal(found, length: pattern.count) } else { NSSound.beep() }
            }
        }
    }

    private func reveal(_ offset: UInt64, length: Int) {
        lastMatch = (offset, length)
        switch currentMode {
        case .text:
            if offset + UInt64(length) > ListerTextView.maxLoadedBytes {
                // Deep match: auto-switch to hex, keep the pattern and match cache
                // (design §6 exception).
                setMode(.hex, auto: true, preserveSearch: true)
                searchBar?.mode = .hex
                searchBar?.setQuerySilently(search!.pattern.map { String(format: "%02X ", $0) }
                    .joined().trimmingCharacters(in: .whitespaces))
                hexView?.highlight(offset: offset, count: length)
                showStatusNote(tr("Match beyond text-mode limit — switched to Hexadecimal"))
            } else {
                textContent?.highlightMatch(atByte: offset, byteLength: length)
            }
        case .hex: hexView?.highlight(offset: offset, count: length)
        case .preview, .plugin: break
        }
        updatePositionLabel()
    }

    // MARK: Page rendering (PageViewerPlugin → ListerWebView)

    /// Runs the plugin's `renderPage` on a detached task and loads the result;
    /// later `update`s from the plugin (e.g. diagrams rendered to SVG) reload
    /// the page while it is still the current one. The loading overlay only
    /// appears if the render outlasts its 250ms grace (small files never flash
    /// it). A throw / failed update shows its message and falls back to the
    /// chooser's mode for the file (md → source, epub → QL, mobi → hex).
    private func startPageRender(_ viewer: PageViewerPlugin, url: URL) {
        let gen = pageGeneration
        let cancel = CancelFlag()
        pageCancel = cancel
        mdWebView?.focus()                           // keyboard goes to the page area right away
        beginLoadingIndicator()
        let deliver: @Sendable (Result<String, Error>) -> Void = { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !cancel.isCancelled, self.pageGeneration == gen else { return }
                switch result {
                case .success(let html):
                    self.mdWebView?.loadHTML(html)
                    // Appearance may have flipped while the plugin was still
                    // rendering — re-check once; the plugin decides cheaply.
                    self.appearanceChangedInPreview()
                case .failure(let error):
                    self.pageRenderFailed(error)
                }
            }
        }
        webRenderTask = Task.detached(priority: .userInitiated) { [weak self] in
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
                guard let self, !cancel.isCancelled, self.pageGeneration == gen else { return }
                self.webRenderTask = nil
                self.endLoadingIndicator()
                switch result {
                case .success(let html):
                    self.mdWebView?.loadHTML(html)
                    self.mdWebView?.focus()
                case .failure(let error):
                    self.pageRenderFailed(error)
                }
            }
        }
    }

    /// The page viewer could not render the file: note + the chooser's mode.
    /// `pageFellBack` keeps the Plugin segment on that fall-back until an
    /// explicit press of 4 re-attempts the render.
    private func pageRenderFailed(_ error: Error) {
        pageFellBack = true
        setMode(builtInChoice, auto: true)
        showStatusNote(tr(error.localizedDescription))     // built-ins throw English source strings
    }

    /// Stops an in-flight render (plugins poll `isCancelled` and bail early)
    /// and drops its loading overlay.
    private func cancelWebRender() {
        pageCancel?.cancel(); pageCancel = nil
        guard let task = webRenderTask else { return }
        task.cancel()
        webRenderTask = nil
        endLoadingIndicator()
    }

    /// Live light/dark switch while the viewer is open (spec §7): re-render the
    /// current page when the plugin says its output depends on the appearance
    /// (mermaid SVGs are baked for one theme; the SVG cache makes it instant).
    private func appearanceChangedInPreview() {
        guard shouldShowWeb(), let viewer = pageViewer, viewer.needsRerenderOnAppearanceChange() else { return }
        setMode(.plugin, auto: true)
    }

    // MARK: Encoding

    @objc private func encodingChanged(_ sender: NSPopUpButton) {
        let enc = EncodingDetector.candidates[sender.indexOfSelectedItem].encoding
        guard enc != currentEncoding, let source else { return }
        let anchor = textContent?.topVisibleByteOffset() ?? 0
        currentEncoding = enc
        cancelSearch(clearQuery: false)     // cache key includes encoding → invalidate; keep the query string
        textContent?.load(source: source, encoding: enc, anchorByte: anchor,
                          fileExtension: currentURL?.pathExtension)
    }

    private func selectEncodingInPopup(_ enc: String.Encoding) {
        if let idx = EncodingDetector.candidates.firstIndex(where: { $0.encoding == enc }) {
            encodingPopup?.selectItem(at: idx)
        }
    }

    // MARK: Status bar

    /// text: encoding popup + wrap checkbox + percent; hex: offset + percent;
    /// preview: just the index/total.
    private func reconfigureStatusBar() {
        encodingPopup?.isHidden = currentMode != .text
        wrapCheck?.isHidden = currentMode != .text
        if currentMode == .text {
            selectEncodingInPopup(currentEncoding)
            wrapCheck?.state = (textContent?.wrapsLines ?? true) ? .on : .off
        }
        updatePositionLabel()
    }

    private func updatePositionLabel() {
        switch currentMode {
        case .text:
            positionLabel?.stringValue = "\(textContent?.percent ?? 0)%"
        case .hex:
            let off = hexView?.topVisibleOffset ?? 0
            positionLabel?.stringValue = String(format: "0x%llX — %d%%", off, hexView?.percent ?? 0)
        case .preview, .plugin:
            positionLabel?.stringValue = entries.isEmpty ? "" : "\(currentIndex + 1)/\(entries.count)"
        }
    }

    /// Transient note (cap reached / auto-switch / read error); clears after 3s.
    /// The generation token keeps an old timer from wiping a newer note, and the
    /// optional-chained label makes a fire-after-close harmless.
    private func showStatusNote(_ text: String) {
        noteGeneration += 1
        let gen = noteGeneration
        // Defer display AND the clear countdown to the next runloop turn: callers
        // may fire mid-way through a >3s synchronous load (End on a huge file),
        // and a wall-clock deadline scheduled now would expire before the first
        // redraw — the note would be cleared without ever being seen.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.noteGeneration == gen else { return }
            self.statusNote?.stringValue = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.noteGeneration == gen else { return }
                self.statusNote?.stringValue = ""
            }
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        navGeneration += 1                       // invalidate any in-flight entry.resolve() (e.g. remote download)
        // Esc/close must actually STOP the work, not just ignore its result: a solid-7z
        // pass would otherwise keep a core busy long after the window is gone.
        resolveTask?.cancel(); resolveTask = nil
        cancelWebRender()
        endLoadingIndicator()
        searchTask?.cancel(); searchTask = nil
        // The cancelled task's MainActor.run exits at its isCancelled guard and
        // never resets the flag; the singleton outlives the window, so a leak
        // here would leave ‹/› disabled in the NEXT viewer session.
        searchBusy = false
        search = nil
        lastMatch = nil
        searchBarVisible = false
        noteGeneration += 1                      // invalidate any pending note-clear
        pageGeneration += 1                   // invalidate any in-flight diagram substitution
        NotificationCenter.default.removeObserver(self)
        previewView?.close()
        mdWebView?.teardown()
        titlebarAccessory?.removeFromParent()
        // Exhaustive teardown of every lazily-built view reference — anything left
        // dangling here would make the SECOND F3 open an empty content area (the
        // views would "exist" but belong to the dead window).
        previewView = nil
        mdWebView = nil
        webCrashed = false
        pageFellBack = false
        pageViewer = nil
        textContent = nil
        hexScroll = nil
        hexView = nil
        searchBar = nil
        loadingOverlay = nil
        loadingSpinner = nil
        statusBar = nil
        container = nil
        modeControl = nil
        titlebarAccessory = nil
        encodingPopup = nil
        wrapCheck = nil
        positionLabel = nil
        statusNote = nil
        containerTopConstraint = nil
        source = nil
        currentURL = nil
        window = nil
        entries = []
        onIndexChange = nil
    }
}

/// Cancellation the host controls and plugins poll from any thread: a task's
/// own `Task.isCancelled` would not reach a plugin's follow-up work (phase-2
/// diagram rendering runs in a task the plugin spawns).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.withLock { flag } }
    func cancel() { lock.withLock { flag = true } }
}
