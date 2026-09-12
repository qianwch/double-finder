import Foundation

/// A Lister (F3) viewer for document-like formats: the plugin turns a file
/// into an HTML page and the HOST shows it in the Lister's own web view. Where
/// `ViewerPlugin` hands over a whole `NSView`, a page viewer keeps every
/// Lister behaviour — it shows under the Plugin segment (4) like any plugin,
/// ⌘= / ⌘- / ⌘0 zoom the page, the loading indicator, light/dark handling
/// and the fall-back to the built-in Text / Hex / Quick Look modes on failure
/// all come from the host. Preview (3) stays plain Quick Look.
///
/// The page is loaded with JavaScript disabled from a private URL that can
/// fetch nothing, so everything it needs (images, fonts, stylesheets) must be
/// inlined (data URIs / `<style>`), and only `#anchor` links and absolute
/// http(s) links (opened in the system browser) work.
public protocol PageViewerPlugin: AnyObject {
    var identifier: String { get }
    /// Shown in Settings ▸ Plugins.
    var displayName: String { get }

    /// Cheap check — `sample` holds up to the first 64 KiB. Must not block.
    /// The first page viewer that claims a file (in load order) renders it.
    func canRender(url: URL, sample: Data) -> Bool

    /// Produce the page for `url` (always a local file; remote items are fetched
    /// first). Called OFF the main thread on a background task; long work
    /// should poll `isCancelled` and give up early. Throwing shows the error's
    /// `localizedDescription` in the Lister's status bar and falls back to the
    /// mode the host would have chosen without the plugin. `update` may be
    /// called later, from any thread, to replace the page while it is still
    /// the one showing — e.g. once slow parts (diagrams) are rendered; a
    /// `.failure` there falls back exactly like a throw. Late updates for a
    /// page the user has already left are ignored by the host.
    func renderPage(url: URL, isCancelled: @escaping @Sendable () -> Bool,
                    update: @escaping @Sendable (Result<String, Error>) -> Void) throws -> String

    /// Asked when the system switched between light and dark while the page
    /// is showing. Return true to have `renderPage` run again (the host
    /// reloads the page from the top). Default false — pages that adapt with
    /// CSS `prefers-color-scheme` need nothing.
    func needsRerenderOnAppearanceChange() -> Bool
}

public extension PageViewerPlugin {
    func needsRerenderOnAppearanceChange() -> Bool { false }
}
