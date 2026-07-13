import AppKit

/// Text-mode content view (design §4): read-only NSTextView fed 4MB chunks,
/// append-only up to a 256MB decoded cap. Byte↔character mapping is kept via
/// per-chunk anchors: exact mapping (re-decode within one chunk) for match
/// highlighting, linear interpolation for scroll percent / encoding re-anchor.
@MainActor
final class ListerTextView: NSView {
    static let chunkSize = 4 << 20
    static let maxLoadedBytes: UInt64 = 256 << 20
    /// Design §3.2: only single-chunk files get highlighted (full decoded string
    /// maps 1:1 onto textStorage — no carry to worry about).
    static let highlightMaxBytes: UInt64 = UInt64(chunkSize)

    var onStatusChange: (() -> Void)?
    var onCapReached: (() -> Void)?          // once per load(); controller shows status note + beep
    var onReadError: (() -> Void)?           // I/O error (deleted file / ejected volume) — design §8
    var onDecodeFallback: (() -> Void)?      // decoder fell back to ISO-8859-1 — design §5/§8

    private let scroll = NSScrollView()
    private let textView: NSTextView
    private var source: ListerSource?
    private var decoder = TextChunkDecoder(encoding: .utf8)
    private(set) var encoding: String.Encoding = .utf8
    private(set) var loadedBytes: UInt64 = 0
    private(set) var reachedEOF = false
    private var capNotified = false
    private var fallbackNotified = false
    private var readErrorNotified = false
    /// (source byte offset where the appended string STARTS, textStorage utf16
    /// length before the append). NOTE: the start is `loadedBytes - decoder.carryCount`,
    /// not `loadedBytes` — see appendChunk.
    private var anchors: [(byte: UInt64, char: Int)] = []
    private var highlightSpec: LanguageSpec?
    private(set) var fontSize: CGFloat = 12
    private var attrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
         .foregroundColor: NSColor.textColor]
    }

    var wrapsLines = true { didSet { applyWrap() } }

    override init(frame: NSRect) {
        textView = NSTextView()
        super.init(frame: frame)
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = false
        textView.isVerticallyResizable = true
        // NSTextView's DEFAULT maxSize height is only 10,000,000pt (~660k lines):
        // past that the frame is clamped — text lays out but can't be scrolled to.
        // Lift the ceiling up front. (In the wrapping branch, widthTracksTextView
        // drives the container width from the frame directly, so this huge
        // maxSize.width is never actually used for wrapping; AppKit will enlarge
        // a too-small maxSize up to the frame size, but it won't shrink this one
        // back down — only the height matters here.)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        addSubview(scroll)
        applyWrap()
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    /// Reset and load from `source` with `encoding`, then scroll so that
    /// `anchorByte` is at the top (loads sequentially up to it, capped).
    func load(source: ListerSource, encoding: String.Encoding, anchorByte: UInt64 = 0,
              fileExtension: String? = nil) {
        self.source = source
        self.encoding = encoding
        decoder = TextChunkDecoder(encoding: encoding)
        loadedBytes = 0; reachedEOF = false; capNotified = false
        fallbackNotified = false; readErrorNotified = false; anchors = []
        // Design §3.2: only offer highlighting for files that fit in one chunk —
        // beyond that the decoded string is split across appends and token
        // NSRanges (computed against the full single-chunk string) would not
        // line up with textStorage.
        highlightSpec = (source.length <= Self.highlightMaxBytes)
            ? fileExtension.flatMap { LanguageSpec.language(forExtension: $0) } : nil
        textView.textStorage?.setAttributedString(NSAttributedString())
        while loadedBytes <= anchorByte, !reachedEOF, appendChunk() {}
        applyHighlightIfEligible()
        scrollToByte(anchorByte)
        onStatusChange?()
    }

    /// Design §3.2: lexical coloring for files that fit in one chunk. The full
    /// decoded string maps 1:1 onto textStorage (no carry), so token NSRanges
    /// apply directly. Dynamic system colors adapt to light/dark automatically.
    private func applyHighlightIfEligible() {
        // Double-guard is deliberate: `highlightSpec` is already nil for files
        // over highlightMaxBytes (set in load()), but `reachedEOF` additionally
        // confirms this specific load actually finished in one chunk (a file of
        // exactly chunkSize bytes hits EOF on the first appendChunk; the nil-spec
        // short-circuit alone wouldn't catch a caller passing a mismatched source).
        guard let spec = highlightSpec, reachedEOF,
              let storage = textView.textStorage, storage.length > 0 else { return }
        let colors: [TokenKind: NSColor] = [
            .keyword: .systemPurple, .string: .systemRed,
            .comment: .systemGreen, .number: .systemBlue,
        ]
        // Coalesce N per-attribute processEditing passes into one.
        storage.beginEditing()
        for token in SyntaxHighlighter.tokenize(storage.string, spec: spec) {
            guard NSMaxRange(token.range) <= storage.length else { continue }  // belt & braces
            storage.addAttribute(.foregroundColor, value: colors[token.kind]!, range: token.range)
        }
        storage.endEditing()
    }

    /// Append the next chunk. false = EOF, cap, or read error.
    @discardableResult
    private func appendChunk() -> Bool {
        guard let source, !reachedEOF else { return false }
        if loadedBytes >= Self.maxLoadedBytes {
            if !capNotified { capNotified = true; onCapReached?() }
            return false
        }
        guard let data = source.read(offset: loadedBytes, count: Self.chunkSize) else {
            // Deleted file / ejected volume (design §8): report once, then treat
            // as terminal — otherwise every scroll retries the read and beeps.
            if !readErrorNotified { readErrorNotified = true; onReadError?() }
            reachedEOF = true
            return false
        }
        if data.isEmpty { reachedEOF = true; return false }
        let willBeEOF = loadedBytes + UInt64(data.count) >= source.length
        // Anchor at the TRUE byte start of the appended string: the decoder may
        // still hold ≤4 carried bytes from the previous chunk. Anchoring at
        // loadedBytes would re-decode from a continuation byte, tripping the
        // Latin-1 fallback and drifting every highlight past the 4MB boundary.
        anchors.append((byte: loadedBytes - UInt64(decoder.carryCount),
                        char: textView.textStorage?.length ?? 0))
        let s = decoder.decode(data, isFinal: willBeEOF)
        textView.textStorage?.append(NSAttributedString(string: s, attributes: attrs))
        loadedBytes += UInt64(data.count)
        if willBeEOF { reachedEOF = true }
        if decoder.usedFallback && !fallbackNotified { fallbackNotified = true; onDecodeFallback?() }
        return true
    }

    /// Load until byte `offset` is decoded. false = beyond cap / unreachable.
    func ensureLoaded(to offset: UInt64) -> Bool {
        guard offset < Self.maxLoadedBytes else { return false }
        while loadedBytes <= offset, !reachedEOF { if !appendChunk() { break } }
        return loadedBytes > offset
    }

    @objc private func boundsChanged() {
        // Near bottom → pull the next chunk (one per notification keeps it smooth).
        let visible = scroll.contentView.bounds
        let docH = textView.frame.height
        if visible.maxY > docH - visible.height, appendChunk() {
            // Re-arm: appending only grows the document frame — the clip bounds
            // don't change, so no new boundsDidChange fires. Without this, dragging
            // the scroller to the bottom loads exactly one chunk and then stalls.
            DispatchQueue.main.async { [weak self] in self?.boundsChanged() }
        }
        onStatusChange?()
    }

    // MARK: byte ↔ char mapping

    /// Exact utf16 index for a loaded byte offset: find the chunk anchor, then
    /// re-decode that chunk's prefix (≤4MB, only on demand for highlights).
    /// Known edge: if the ORIGINAL decode of this chunk fell back to Latin-1 but
    /// the (shorter) prefix re-decode succeeds in the primary encoding, the utf16
    /// count can drift within that one chunk — accepted graceful degradation.
    private func charIndex(forByte target: UInt64) -> Int? {
        guard target <= loadedBytes, let source,
              let aIdx = anchors.lastIndex(where: { $0.byte <= target }) else { return nil }
        let a = anchors[aIdx]
        guard target > a.byte else { return a.char }
        guard let prefix = source.read(offset: a.byte, count: Int(target - a.byte)) else { return nil }
        var d = TextChunkDecoder(encoding: encoding)
        return a.char + d.decode(prefix, isFinal: false).utf16.count
    }

    /// Approximate utf16 index for a byte offset by linear interpolation between
    /// chunk anchors — used when the exact mapping returns nil: the target byte
    /// lies beyond `loadedBytes` (e.g. a hex-mode anchor past the 256MB cap) or
    /// the prefix re-read failed. For beyond-cap targets frac > 1 extrapolates
    /// past storage.length — callers rely on `scrollRangeToVisible` clamping
    /// out-of-range locations to the end of the loaded text (deepest loaded spot).
    private func approxCharIndex(forByte target: UInt64) -> Int {
        guard let aIdx = anchors.lastIndex(where: { $0.byte <= target }) else { return 0 }
        let a = anchors[aIdx]
        let endByte = aIdx + 1 < anchors.count ? anchors[aIdx + 1].byte : loadedBytes
        let endChar = aIdx + 1 < anchors.count ? anchors[aIdx + 1].char
                                               : (textView.textStorage?.length ?? a.char)
        guard endByte > a.byte, endChar > a.char else { return a.char }
        let frac = Double(target - a.byte) / Double(endByte - a.byte)
        return a.char + Int(frac * Double(endChar - a.char))
    }

    /// Approximate byte offset of the top visible line (linear interpolation
    /// between chunk anchors — design §3/§5 allows this).
    func topVisibleByteOffset() -> UInt64 {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return 0 }
        let topPoint = scroll.contentView.bounds.origin
        let glyph = lm.glyphIndex(for: topPoint, in: tc)
        let char = lm.characterIndexForGlyph(at: glyph)
        guard let aIdx = anchors.lastIndex(where: { $0.char <= char }) else { return 0 }
        let a = anchors[aIdx]
        let endByte = aIdx + 1 < anchors.count ? anchors[aIdx + 1].byte : loadedBytes
        let endChar = aIdx + 1 < anchors.count ? anchors[aIdx + 1].char : storage.length
        guard endChar > a.char else { return a.byte }
        let frac = Double(char - a.char) / Double(endChar - a.char)
        return a.byte + UInt64(frac * Double(endByte - a.byte))
    }

    private func scrollToByte(_ byte: UInt64) {
        guard byte > 0 else { textView.scroll(.zero); return }
        // charIndex is nil when the byte is beyond loadedBytes (anchor past the
        // cap) or the prefix re-read failed — degrade to the interpolated anchor
        // mapping rather than jumping to the top. Out-of-range results are
        // clamped by scrollRangeToVisible (do not add a bounds assertion here).
        let idx = charIndex(forByte: byte) ?? approxCharIndex(forByte: byte)
        textView.scrollRangeToVisible(NSRange(location: idx, length: 0))
    }

    /// Select + reveal a search match (exact mapping; length = utf16 count of
    /// the needle bytes decoded with the current encoding).
    func highlightMatch(atByte offset: UInt64, byteLength: Int) {
        guard byteLength >= 1 else { return }
        // ensureLoaded(to:) is exclusive (requires loadedBytes > offset), so probe
        // the LAST byte of the match (byteLength >= 1) — probing one past the end
        // would make a match ending at the file's final byte unreachable.
        guard ensureLoaded(to: offset + UInt64(byteLength) - 1),
              let start = charIndex(forByte: offset), let source else { return }
        var len = 1
        if let nb = source.read(offset: offset, count: byteLength) {
            var d = TextChunkDecoder(encoding: encoding)
            len = max(1, d.decode(nb, isFinal: true).utf16.count)
        }
        let range = NSRange(location: start, length: len)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    /// ⌘=/⌘-/⌘0 zoom. With `reapply` the loaded text is restyled in place
    /// (foregroundColor highlights survive) keeping the top byte anchored;
    /// without it only the size is recorded — the next load() picks it up
    /// (the controller reloads text content on every mode switch).
    func setFontSize(_ size: CGFloat, reapply: Bool) {
        guard size != fontSize else { return }
        fontSize = size
        guard reapply, let storage = textView.textStorage, storage.length > 0 else { return }
        let anchor = topVisibleByteOffset()
        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: size, weight: .regular),
                             range: NSRange(location: 0, length: storage.length))
        scrollToByte(anchor)
        onStatusChange?()
    }

    func pageDown() { textView.scrollPageDown(nil) }
    func focus() { window?.makeFirstResponder(textView) }

    /// End key: load to EOF or the 256MB cap in one go, then jump to the bottom.
    /// (Scroll-driven loading appends one 4MB chunk per bounds change — reaching
    /// the cap that way would take ~60 keypresses.)
    func loadToEnd() {
        while !reachedEOF { if !appendChunk() { break } }
        textView.scrollToEndOfDocument(nil)
        onStatusChange?()
    }

    var percent: Int {
        guard let source, source.length > 0 else { return 100 }
        return Int(min(100, (topVisibleByteOffset() * 100) / source.length))
    }

    private func applyWrap() {
        guard let tc = textView.textContainer else { return }
        if wrapsLines {
            tc.widthTracksTextView = true
            textView.isHorizontallyResizable = false
            textView.frame.size.width = scroll.contentSize.width
            tc.containerSize = NSSize(width: scroll.contentSize.width,
                                      height: .greatestFiniteMagnitude)
        } else {
            tc.widthTracksTextView = false
            textView.isHorizontallyResizable = true
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
            tc.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                      height: CGFloat.greatestFiniteMagnitude)
        }
        scroll.hasHorizontalScroller = !wrapsLines
    }
}
