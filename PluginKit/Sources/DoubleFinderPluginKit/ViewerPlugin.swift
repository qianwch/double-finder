import AppKit

/// A Lister (F3) viewer plugin (TC "WLX"): renders files of some kind in its own
/// view. When a plugin claims a file it becomes the Lister's auto-chosen mode;
/// the user can still switch to Text / Hex / Preview with 1 / 2 / 3 and back
/// with 4.
public protocol ViewerPlugin: AnyObject {
    var identifier: String { get }
    /// Shown in the Lister's mode control tooltip and Settings ▸ Plugins.
    var displayName: String { get }

    /// Cheap check — `sample` holds up to the first 64 KiB. Must not block.
    func canView(url: URL, sample: Data) -> Bool

    /// Build the view for `url` (always a local file; remote items are fetched
    /// first). The host sizes it to the content area. Throw to fall back to the
    /// built-in modes.
    @MainActor func makeView(for url: URL) throws -> NSView
}
