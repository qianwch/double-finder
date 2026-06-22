import AppKit
import QuickLookThumbnailing

/// Asynchronous file-icon and QuickLook-thumbnail provider with an in-memory
/// bitmap cache. The public API is fully main-thread — `draw(_:)` can call
/// `icon(for:side:wantThumbnail:)` without any synchronous disk or
/// LaunchServices work; it gets either a cached bitmap or a generic placeholder
/// immediately, while real resolution happens on a background queue and
/// invalidates the row via `onReady`.
@MainActor
final class FileIconProvider {

    // MARK: - Public interface

    /// Called on the **main thread** with the file path whenever its icon or
    /// thumbnail finished loading and the cache was updated.
    var onReady: ((String) -> Void)?

    /// Returns the cached bitmap for `item` at `side × side` points, or a
    /// generic placeholder if nothing is cached yet. When a miss occurs the
    /// real icon (and optionally a QuickLook thumbnail) is resolved in the
    /// background; `onReady(path)` is called on the main thread when done.
    ///
    /// - Never blocks on disk, LaunchServices, or QL.
    /// - Caller must handle `..` before calling here.
    func icon(for item: FileItem, side: CGFloat, wantThumbnail: Bool) -> NSImage {
        let key = cacheKey(path: item.path, side: side)
        if let cached = cache[key] { return cached }

        // Cache miss: return the generic placeholder immediately…
        let placeholder = genericPlaceholder(side: side)

        // …and enqueue background resolution if not already pending / running.
        if !pending.contains(key) {
            pending.insert(key)
            enqueue(item: item, side: side, wantThumbnail: wantThumbnail, key: key)
        }
        return placeholder
    }

    /// Enqueues icon resolution for the given items (e.g. the visible rows).
    /// Items already cached or pending are silently skipped.
    func prefetch(_ items: [FileItem], side: CGFloat, thumbnails: Bool) {
        for item in items {
            let key = cacheKey(path: item.path, side: side)
            guard cache[key] == nil, !pending.contains(key) else { continue }
            pending.insert(key)
            enqueue(item: item, side: side, wantThumbnail: thumbnails, key: key)
        }
    }

    /// Drops not-yet-started operations whose path is not in `keepPaths`.
    /// Operations that are already executing are left to finish.
    func cancelOffscreen(keepPaths: Set<String>) {
        // Cancel queued (not-yet-started) operations whose path is not wanted.
        let ops = queue.operations.compactMap { $0 as? IconOperation }
        for op in ops where !keepPaths.contains(op.path) {
            op.cancel()
            pending.remove(cacheKey(path: op.path, side: op.side))
        }
    }

    /// Empties the icon/thumbnail cache. Pending operations are cancelled.
    /// The next `icon(for:)` call will enqueue fresh resolution.
    func clear() {
        queue.cancelAllOperations()
        pending.removeAll()
        cache.removeAll(keepingCapacity: true)
        // Keep placeholderCache — those are generic and never stale.
    }

    // MARK: - Private state

    /// Path+side keyed bitmap cache. All reads and writes on the main thread.
    private var cache: [String: NSImage] = [:]

    /// Keys for which a background operation is already pending or running.
    private var pending: Set<String> = []

    /// Generic placeholder images indexed by side length (resolved once per size).
    private var placeholderCache: [CGFloat: NSImage] = [:]

    /// Background operation queue — at most 4 resolutions run concurrently.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "FileIconProvider.resolution"
        q.maxConcurrentOperationCount = 4
        return q
    }()

    // MARK: - Helpers

    private func cacheKey(path: String, side: CGFloat) -> String {
        "\(path)|\(Int(side))"
    }

    /// Returns (and memoises) a generic placeholder at the requested size.
    private func genericPlaceholder(side: CGFloat) -> NSImage {
        if let existing = placeholderCache[side] { return existing }
        let raw = NSWorkspace.shared.icon(for: .data)
        let placeholder = fileIconResized(raw, to: side)
        placeholderCache[side] = placeholder
        return placeholder
    }

    /// Schedules a background `IconOperation` for `item`.
    private func enqueue(item: FileItem, side: CGFloat, wantThumbnail: Bool, key: String) {
        let op = IconOperation(item: item, side: side, wantThumbnail: wantThumbnail)
        op.onComplete = { [weak self] path, image in
            // Already on main thread (IconOperation hops back).
            guard let self else { return }
            self.pending.remove(key)
            self.cache[key] = image
            self.onReady?(path)
        }
        queue.addOperation(op)
    }

}

// MARK: - Shared utility (nonisolated — safe to call from any thread)

/// Renders `source` into a fixed `side × side` bitmap.
/// Marked nonisolated so it can be called both from @MainActor code and from
/// background `Operation.main()` without a concurrency error.
func fileIconResized(_ source: NSImage, to side: CGFloat) -> NSImage {
    let size = NSSize(width: side, height: side)
    // Flatten to a CGImage first (definite top-left orientation). System icons —
    // folders in particular — are returned as flip-sensitive images that bake in
    // upside-down when drawn straight into an NSImage focus, so the cached bitmap
    // ended up inverted in our flipped list view. A CGImage-backed bitmap is a
    // plain top-left bitmap that draws uprightly (with respectFlipped at the call
    // site) the same way for every icon type.
    var rect = NSRect(origin: .zero, size: size)
    let img = NSImage(size: size)
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    if let cg = source.cgImage(forProposedRect: &rect, context: NSGraphicsContext.current, hints: nil) {
        NSImage(cgImage: cg, size: size).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    } else {
        source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    img.unlockFocus()
    return img
}

// MARK: - IconOperation

/// A cancellable `Operation` that resolves one file's icon (or QuickLook
/// thumbnail) off the main thread, then delivers the result to the main thread.
private final class IconOperation: Operation {

    let path: String
    let side: CGFloat
    private let item: FileItem
    private let wantThumbnail: Bool

    /// Called on the **main thread** with (path, resized image).
    var onComplete: ((String, NSImage) -> Void)?

    init(item: FileItem, side: CGFloat, wantThumbnail: Bool) {
        self.item = item
        self.path = item.path
        self.side = side
        self.wantThumbnail = wantThumbnail
    }

    override func main() {
        guard !isCancelled else { return }

        if wantThumbnail && !item.isDirectory {
            resolveThumbnail()
        } else {
            resolveWorkspaceIcon()
        }
    }

    // MARK: Workspace icon (synchronous off-main)

    private func resolveWorkspaceIcon() {
        guard !isCancelled else { return }
        let raw: NSImage
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            // NSWorkspace.icon(forFile:) is documented to be safe off main in
            // macOS 10.6+.
            raw = NSWorkspace.shared.icon(forFile: path)
        } else if item.isDirectory {
            raw = NSWorkspace.shared.icon(for: .folder)
        } else {
            raw = NSWorkspace.shared.icon(for: .data)
        }
        guard !isCancelled else { return }
        deliver(raw)
    }

    // MARK: QuickLook thumbnail (async API — we run it with a semaphore)

    private func resolveThumbnail() {
        guard FileManager.default.fileExists(atPath: path), !isCancelled else {
            resolveWorkspaceIcon()
            return
        }
        let url = URL(fileURLWithPath: path)
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: side, height: side),
            scale: 2.0,
            representationTypes: .thumbnail
        )
        let semaphore = DispatchSemaphore(value: 0)
        var resolved: NSImage?
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            resolved = rep?.nsImage
            semaphore.signal()
        }
        semaphore.wait()
        guard !isCancelled else { return }
        deliver(resolved ?? NSWorkspace.shared.icon(forFile: path))
    }

    // MARK: Delivery

    private func deliver(_ image: NSImage) {
        let resized = fileIconResized(image, to: side)
        let capturedPath = path
        let capturedOnComplete = onComplete
        DispatchQueue.main.async {
            capturedOnComplete?(capturedPath, resized)
        }
    }
}
