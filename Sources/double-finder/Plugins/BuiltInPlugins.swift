import DoubleFinderPluginKit

/// Plugins compiled into the app. They are loaded through `PluginManager` like
/// any bundle (same lifecycle, same enable/disable switch in Settings), which
/// keeps the public API honest: whatever a built-in needs, an external plugin
/// can do too. Add a type here to ship a new one. Order = claim precedence.
enum BuiltInPlugins {
    static let all: [DFPlugin.Type] = [
        MarkdownPreviewPlugin.self,   // .md / .mmd / .puml → rendered page (PageViewerPlugin)
        EbookReaderPlugin.self,       // .epub / .mobi / .azw3 → rendered book (PageViewerPlugin)
    ]
}
