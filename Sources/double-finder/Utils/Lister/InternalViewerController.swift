import AppKit
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
    private var modeControl: NSSegmentedControl?      // titlebar accessory: Text/Hexadecimal/Preview
    private var titlebarAccessory: NSTitlebarAccessoryViewController?
    private var textContent: ListerTextView?          // lazy
    private var hexScroll: NSScrollView?              // lazy, documentView = hexView
    private var hexView: ListerHexView?
    private var previewView: QLPreviewView?           // lazy (was eagerly built pre-Lister)
    private var mdWebView: ListerWebView?             // lazy, rendered markdown in preview mode
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
    /// Set ONLY when a crashed WKWebView gives up twice (design §4.1) — makes
    /// showWeb false so preview stays on source. Reset per-file in load(). It is
    /// deliberately NOT set on oversize/read-error redirects: those fall to source
    /// too, but a second press-3 must re-attempt the render, not jump to QL.
    private var mdRenderFellBack = false
    /// Max markdown size we read fully into memory to render (design §4.1).
    private let mdRenderMaxBytes: UInt64 = 2 << 20

    // Search state (one ListerSearch instance per file+pattern+encoding+case key)
    private var search: ListerSearch?
    private var searchTask: Task<Void, Never>?
    private var lastMatch: (offset: UInt64, length: Int)?
    // True for the duration of an in-flight forward scan. Guards every synchronous,
    // main-actor read of `search!.matches` (Find Previous, and `validateQuery`'s
    // re-enabling of ‹/›) against the detached scan task concurrently appending to
    // that same array — `ListerSearch` is only safe under single-task exclusivity.
    private var searchBusy = false

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
        let seg = NSSegmentedControl(labels: [tr("Text"), tr("Hexadecimal"), tr("Preview")],
                                     trackingMode: .selectOne,
                                     target: self, action: #selector(modeChanged(_:)))
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

    /// True when preview mode should show rendered markdown (ListerWebView)
    /// rather than QLPreviewView. False after a WKWebView crash-give-up.
    private func shouldShowWeb() -> Bool {
        currentMode == .preview && isMarkdownURL(currentURL) && !mdRenderFellBack
    }

    /// A markdown file by extension (md/markdown), routed to rendered preview.
    private func isMarkdownURL(_ url: URL?) -> Bool {
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return ext == "md" || ext == "markdown"
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
                wireTextCallbacks(tv)
                container.addSubview(tv)
                textContent = tv
            }
        case .hex:
            if hexView == nil {
                let hv = ListerHexView()
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
        case .preview:
            if showWeb {
                if mdWebView == nil {
                    let wv = ListerWebView(frame: container.bounds)
                    wv.autoresizingMask = [.width, .height]
                    wv.onGiveUp = { [weak self] in
                        guard let self else { return }
                        self.mdRenderFellBack = true
                        self.setMode(.text, auto: true)
                        self.showStatusNote(tr("Preview failed — showing source"))
                    }
                    container.addSubview(wv)
                    mdWebView = wv
                }
            } else if previewView == nil {
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
        previewView?.isHidden = !(currentMode == .preview && !showWeb)
        mdWebView?.isHidden = !showWeb
        if currentMode == .preview {
            if showWeb {
                previewView?.previewItem = nil          // free QL, hand focus to web
                mdWebView?.focus()
            } else {
                mdWebView?.loadHTML("")                  // drop any stale rendered doc
            }
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
        let modes: [ViewerMode] = [.text, .hex, .preview]
        guard modes.indices.contains(sender.selectedSegment) else { return }
        setMode(modes[sender.selectedSegment], auto: false)
    }

    @objc private func wrapToggled(_ sender: NSButton) {
        textContent?.wrapsLines = (sender.state == .on)
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
                    if event.charactersIgnoringModifiers == "f" { self.toggleSearchBar(); return nil }
                    return event
                }
            }
            let bare = event.modifierFlags.intersection([.option, .control, .shift]).isEmpty
            switch event.keyCode {
            case 18 where bare: self.setMode(.text, auto: false); return nil     // 1 (not ⌥/⌃ combos)
            case 19 where bare: self.setMode(.hex, auto: false); return nil      // 2
            case 20 where bare: self.setMode(.preview, auto: false); return nil  // 3
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
        mdRenderFellBack = false                     // per-file: give the next md a fresh render attempt
        Task { [weak self] in
            let url = await entry.resolve()
            guard let self, self.navGeneration == gen else { return }
            guard let url else {
                self.source = nil; self.currentURL = nil
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
            self.setMode(choice.mode, auto: true)
            self.window?.title = "\(entry.title) — (\(index + 1)/\(total))"
            self.onIndexChange?(index)
        }
    }

    // MARK: Mode switching

    /// Shared by manual 1/2/3 switches and per-file auto routing; `preserveSearch`
    /// is only used by the deep-match auto-switch to hex.
    private func setMode(_ mode: ViewerMode, auto: Bool, preserveSearch: Bool = false) {
        if !preserveSearch, !auto { cancelSearch(clearQuery: true) }   // manual switch clears the search (design §6)
        // Manual same-file switches keep the reading position by byte offset
        // (same anchoring as encoding changes; TC behavior).
        let anchor: UInt64 = (!auto && mode != .preview) ? currentTopByteOffset() : 0
        currentMode = mode
        modeControl?.selectedSegment = [.text: 0, .hex: 1, .preview: 2][mode]!
        showOnlyCurrentModeView()
        switch mode {
        case .text:
            if let source {
                textContent?.load(source: source, encoding: currentEncoding, anchorByte: anchor,
                                  fileExtension: currentURL?.pathExtension)
            }
            textContent?.focus()
        case .hex:
            if let source { hexView?.load(source: source) }
            if anchor > 0 { hexView?.scrollToOffset(anchor) }
            hexView?.focus()
        case .preview:
            if shouldShowWeb(), let source {
                // Size-before-read (order is critical: never read a huge md fully
                // into memory). Oversize/read-error redirect to source WITHOUT
                // setting mdRenderFellBack — that flag is crash-only, and setting
                // it here would make a second press-3 wrongly jump to QL.
                if source.length > mdRenderMaxBytes {
                    setMode(.text, auto: true)
                    showStatusNote(tr("Markdown too large — showing source"))
                    return
                }
                guard let data = source.read(offset: 0, count: Int(source.length)) else {
                    setMode(.text, auto: true)
                    showStatusNote(tr("Read error — cannot access the file"))
                    return
                }
                var decoder = TextChunkDecoder(encoding: currentEncoding)
                let text = decoder.decode(data, isFinal: true)
                let html = MarkdownToHTML.render(text, baseDir: currentURL?.deletingLastPathComponent())
                mdWebView?.loadHTML(html)
                mdWebView?.focus()
            } else {
                previewView?.previewItem = currentURL as NSURL?
                window?.makeFirstResponder(previewView)
            }
        }
        searchBar?.mode = (mode == .hex) ? .hex : .text
        reconfigureStatusBar()
    }

    // MARK: Search

    private func toggleSearchBar() {
        guard currentMode != .preview else { NSSound.beep(); return }  // QL mode has no byte view to search
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
        case .preview: return 0
        }
    }

    private func find(backwards: Bool) {
        guard currentMode != .preview else { NSSound.beep(); return }  // QL mode has no byte view to search
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
        case .preview: break
        }
        updatePositionLabel()
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
        case .preview:
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
        searchTask?.cancel(); searchTask = nil
        // The cancelled task's MainActor.run exits at its isCancelled guard and
        // never resets the flag; the singleton outlives the window, so a leak
        // here would leave ‹/› disabled in the NEXT viewer session.
        searchBusy = false
        search = nil
        lastMatch = nil
        searchBarVisible = false
        noteGeneration += 1                      // invalidate any pending note-clear
        NotificationCenter.default.removeObserver(self)
        previewView?.close()
        mdWebView?.teardown()
        titlebarAccessory?.removeFromParent()
        // Exhaustive teardown of every lazily-built view reference — anything left
        // dangling here would make the SECOND F3 open an empty content area (the
        // views would "exist" but belong to the dead window).
        previewView = nil
        mdWebView = nil
        mdRenderFellBack = false
        textContent = nil
        hexScroll = nil
        hexView = nil
        searchBar = nil
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
