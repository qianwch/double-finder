import AppKit

// MARK: - Drop destination (NSDraggingDestination)

/// Everything about receiving a drag: where it would land, whether that row
/// lights up, and whether it is a copy or a move. Split out of
/// `FileListBodyView.swift` to keep that file focused on drawing and input.
extension FileListBodyView {

    // MARK: Pasteboard reading

    func canAcceptDrop(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                options: [.urlReadingFileURLsOnly: true])
    }

    /// Source paths carried by the drag, cached per dragging session.
    ///
    /// `draggingUpdated` fires continuously (AppKit sends periodic updates even
    /// while the mouse is still), and `readObjects` is a cross-process pasteboard
    /// round-trip — reading it on every callback is the same hot-loop mistake
    /// `draw()` avoids with its "never read UserDefaults per row" rule. The
    /// pasteboard cannot change within one drag, so key the cache on
    /// `draggingSequenceNumber` and clear it when the drag ends.
    private func draggedPaths(_ sender: NSDraggingInfo) -> [String] {
        if draggedPathsSequence == sender.draggingSequenceNumber {
            return draggedPathsCache
        }
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        draggedPathsCache = urls.map { $0.path }
        draggedPathsSequence = sender.draggingSequenceNumber
        return draggedPathsCache
    }

    /// Clears the per-session pasteboard cache. Called when a drag leaves or ends.
    private func clearDraggedPathsCache() {
        draggedPathsSequence = nil
        draggedPathsCache = []
    }

    // MARK: Destination resolution

    /// The directory this drag would land in, given where the mouse is now.
    func dropDestination(for sender: NSDraggingInfo) -> String {
        let p = convert(sender.draggingLocation, from: nil)
        let row = geometry.rowAt(point: p, count: items.count)
        return FileDropTarget.dropDestinationDir(row: row, items: items, currentPath: currentPath)
    }

    /// Updates `dropHighlightRow` for the current mouse position. A row lights up
    /// only when it is a real sub-directory target AND at least one dragged source
    /// could legally land there — the same `selfTransferSources` guard the drop
    /// handler applies, so the highlight never promises an operation that will be
    /// refused on release.
    private func updateDropHighlight(for sender: NSDraggingInfo) {
        let p = convert(sender.draggingLocation, from: nil)
        guard let row = geometry.rowAt(point: p, count: items.count), row < items.count else {
            dropHighlightRow = nil; return
        }
        let dest = FileDropTarget.dropDestinationDir(row: row, items: items, currentPath: currentPath)
        // Resolved back to currentPath → this row is not a target (file / package / "..").
        guard dest != currentPath || items[row].name == ".." else {
            dropHighlightRow = nil; return
        }
        let paths = draggedPaths(sender)
        let blocked = Set(FileOperation.selfTransferSources(paths, destDir: dest))
        dropHighlightRow = paths.contains(where: { !blocked.contains($0) }) ? row : nil
    }

    // MARK: Operation semantics

    /// TC semantics: dragging inside one panel rearranges files (move); dragging
    /// across panels brings a copy. ⌘ inverts either default.
    ///
    /// In-app drags declare `ignoreModifierKeys(for:) == true`, so the mask
    /// arrives unfiltered and `NSEvent.modifierFlags` is ours to interpret.
    ///
    /// External sources (Finder, other apps) are a different contract: AppKit
    /// AND-filters *their* mask by the held modifiers, so what arrives is what
    /// that app is willing to do right now — we honour it rather than second-
    /// guessing it. `.generic` (what several apps send under ⌘) is treated as a
    /// copy: silently defaulting it to `.move` would delete the user's original
    /// in the source app, and returning `[]` would make the drop dead with no
    /// explanation.
    func dropOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard canAcceptDrop(sender) else { return [] }
        let mask = sender.draggingSourceOperationMask

        guard let source = sender.draggingSource as? FileListBodyView else {
            if mask.contains(.copy) { return .copy }
            if mask.contains(.generic) { return .copy }   // ambiguous → the safe one
            return mask.contains(.move) ? .move : []
        }
        var wantsMove = (source === self)
        if NSEvent.modifierFlags.contains(.command) { wantsMove.toggle() }
        return wantsMove ? .move : .copy
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropHighlight(for: sender)
        return dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDropHighlight(for: sender)
        // Auto-scroll when the pointer passes the top/bottom edge of a long list.
        // `draggingUpdated` has no NSEvent of its own; the current event is the
        // conventional stand-in (guarded — a synthesized drag may have none).
        if let event = NSApp.currentEvent { autoscroll(with: event) }
        return dropOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlightRow = nil
        clearDraggedPathsCache()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHighlightRow = nil
        clearDraggedPathsCache()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlightRow = nil
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        let move = dropOperation(for: sender) == .move
        let destDir = dropDestination(for: sender)
        if let d = fileDelegate {
            d.fileTableView(self, didDropFiles: urls, move: move, destDir: destDir)
        } else {
            onDropFiles?(urls, move, destDir)
        }
        return true
    }
}
