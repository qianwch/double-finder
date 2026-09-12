import AppKit
import DoubleFinderPluginKit

/// Built-in page viewer: EPUB and Kindle books (`.epub` / `.mobi` / `.prc` /
/// `.azw` / `.azw3` / `.kf8`) rendered as one page with a table-of-contents
/// sidebar (`EPUBReader` / `MOBIReader` / `EbookHTML`). Switch it off in
/// Settings ▸ Plugins and F3 hands `.epub` to Quick Look and the Kindle
/// containers to the hex view.
final class EbookReaderPlugin: NSObject, DFPlugin {
    static let identifier = "net.qian.double-finder.ebook"

    var info: PluginInfo {
        MainActor.assumeIsolated { PluginInfo(identifier: Self.identifier, name: tr("Ebook Reader"), version: "1.0",
                   summary: tr("Reads EPUB and Kindle (MOBI / AZW3) books in the Lister"),
                   author: "Double Finder") }
    }

    private let viewer = EbookPageViewer()

    override init() { super.init() }

    func activate(host: PluginHost) throws {}

    var pageViewers: [PageViewerPlugin] { [viewer] }
}

final class EbookPageViewer: PageViewerPlugin, Sendable {
    let identifier = "ebook"
    var displayName: String { MainActor.assumeIsolated { tr("Ebook Reader") } }

    static let extensions: Set<String> = ["epub", "mobi", "prc", "azw", "azw3", "kf8"]

    /// Max container size handed to the readers (the whole file is unpacked /
    /// decompressed in memory; images are inlined up to a separate 48 MB budget,
    /// see `EbookResourceBudget`).
    static let maxBytes = 512 << 20

    func canRender(url: URL, sample: Data) -> Bool {
        Self.extensions.contains(url.pathExtension.lowercased())
    }

    func renderPage(url: URL, isCancelled: @escaping @Sendable () -> Bool,
                    update: @escaping @Sendable (Result<String, Error>) -> Void) throws -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxBytes else { throw PageError("Ebook too large to render") }
        do {
            let book = url.pathExtension.lowercased() == "epub"
                ? try EPUBReader.read(url: url, isCancelled: isCancelled)
                : try MOBIReader.read(url: url, isCancelled: isCancelled)
            if isCancelled() { throw CancellationError() }
            return EbookHTML.page(for: book)
        } catch EbookError.drm {
            throw PageError("Ebook is DRM-protected — cannot display")
        } catch EbookError.unsupported(let what) {
            throw PageError(what == "KFX" ? "KFX books are not supported — showing hexadecimal"
                                          : "Unsupported ebook format — showing hexadecimal")
        } catch EbookError.cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            NSLog("[ebook] %@: %@", url.lastPathComponent, String(describing: error))
            throw PageError("Cannot read ebook — showing hexadecimal")
        }
    }
}
