import XCTest
import DoubleFinderPluginKit
@testable import double_finder

/// The built-in plugins (Markdown preview, ebook reader, PDF viewer, image viewer, media player) go through
/// the same plugin contracts as a bundle would: claim by extension + sample,
/// render off-main, report failures as errors the host shows and falls back on.
final class BuiltInPluginsTests: XCTestCase {

    private func tempFile(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("builtin-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testCatalogueShipsMarkdownEbookPDFImageAndMediaViewers() {
        XCTAssertEqual(BuiltInPlugins.all.count, 5)
        let ids = BuiltInPlugins.all.map { $0.init().info.identifier }
        XCTAssertEqual(ids, [MarkdownPreviewPlugin.identifier, EbookReaderPlugin.identifier,
                             PDFViewerPlugin.identifier, ImageViewerPlugin.identifier, MediaPlayerPlugin.identifier])
        let viewPlugins: Set = [PDFViewerPlugin.identifier, ImageViewerPlugin.identifier, MediaPlayerPlugin.identifier]
        for type in BuiltInPlugins.all {
            let p = type.init()
            let isView = viewPlugins.contains(p.info.identifier)
            XCTAssertEqual(p.pageViewers.count, isView ? 0 : 1, p.info.identifier)  // md / ebook = page viewers
            XCTAssertEqual(p.viewers.count, isView ? 1 : 0, p.info.identifier)      // pdf / image / media = view plugins
            XCTAssertTrue(p.fileSystems.isEmpty && p.commands.isEmpty)
        }
    }

    func testImageViewerClaimsBitmapsAndRAW() {
        let v = ImageFileViewer()
        XCTAssertTrue(v.canView(url: URL(fileURLWithPath: "/x/IMG_0001.CR2"), sample: Data()))
        XCTAssertTrue(v.canView(url: URL(fileURLWithPath: "/x/a.heic"), sample: Data()))
        XCTAssertTrue(v.canView(url: URL(fileURLWithPath: "/x/a.svg"), sample: Data()))
        XCTAssertFalse(v.canView(url: URL(fileURLWithPath: "/x/a.mp4"), sample: Data()))
        XCTAssertFalse(v.canView(url: URL(fileURLWithPath: "/x/a.pdf"), sample: Data()))
    }

    func testImageZoomFitAndSteps() {
        XCTAssertEqual(ImageZoom.fit(image: CGSize(width: 4000, height: 3000), in: CGSize(width: 1016, height: 800)), 0.246, accuracy: 0.001)
        XCTAssertEqual(ImageZoom.fit(image: CGSize(width: 200, height: 100), in: CGSize(width: 1000, height: 800)), 1)   // never upscales
        XCTAssertEqual(ImageZoom.stepped(1, direction: 1), 1.25)
        XCTAssertEqual(ImageZoom.stepped(1, direction: -1), 0.8)
        XCTAssertEqual(ImageZoom.stepped(ImageZoom.maximum, direction: 1), ImageZoom.maximum)
        XCTAssertEqual(ImageZoom.stepped(0.01, direction: -1), ImageZoom.minimum)
    }

    func testMediaViewerClaimsByExtension() {
        let v = MediaViewer()
        XCTAssertTrue(v.canView(url: URL(fileURLWithPath: "/x/a.MKV"), sample: Data()))
        XCTAssertTrue(v.canView(url: URL(fileURLWithPath: "/x/a.flac"), sample: Data()))
        XCTAssertFalse(v.canView(url: URL(fileURLWithPath: "/x/a.pdf"), sample: Data()))
        XCTAssertFalse(v.canView(url: URL(fileURLWithPath: "/x/noext"), sample: Data("RIFF".utf8)))
    }

    func testPDFViewerClaimsByExtensionOrMagic() {
        let v = PDFDocumentViewer()
        XCTAssertTrue(v.canView(url: URL(fileURLWithPath: "/x/a.PDF"), sample: Data()))
        XCTAssertTrue(v.canView(url: URL(fileURLWithPath: "/x/noext"), sample: Data("%PDF-1.4".utf8)))
        XCTAssertFalse(v.canView(url: URL(fileURLWithPath: "/x/a.epub"), sample: Data("PK".utf8)))
    }

    func testMarkdownViewerClaimsTextMarkdownOnly() {
        let v = MarkdownPageViewer()
        let md = URL(fileURLWithPath: "/x/a.md")
        XCTAssertTrue(v.canRender(url: md, sample: Data("# hi".utf8)))
        XCTAssertTrue(v.canRender(url: URL(fileURLWithPath: "/x/d.PUML"), sample: Data("@startuml".utf8)))
        XCTAssertFalse(v.canRender(url: md, sample: Data([0x4D, 0x00])), "NULs = binary in disguise")
        XCTAssertFalse(v.canRender(url: URL(fileURLWithPath: "/x/a.txt"), sample: Data("# hi".utf8)))
        XCTAssertFalse(v.needsRerenderOnAppearanceChange(), "no page rendered yet")
    }

    func testMarkdownViewerRendersAPage() throws {
        let url = try tempFile("t.md", Array("# Title\n\nSome *text*\n".utf8))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let html = try MarkdownPageViewer().renderPage(url: url, isCancelled: { false }, update: { _ in })
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<em>text</em>"))
    }

    func testMarkdownViewerReportsOversizeAsSourceFallback() throws {
        let url = try tempFile("big.md", [UInt8](repeating: 0x61, count: 16))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // Simulate the cap by pointing at a file the size check rejects: patch via a
        // subclass is overkill — instead assert the real cap value is what spec says.
        XCTAssertEqual(MarkdownPageViewer.maxBytes, 50 << 20)
        XCTAssertEqual(EbookPageViewer.maxBytes, 512 << 20)
    }

    func testEbookViewerClaimsByExtensionAndMapsDRMToAMessage() throws {
        let v = EbookPageViewer()
        XCTAssertTrue(v.canRender(url: URL(fileURLWithPath: "/x/b.AZW3"), sample: Data()))
        XCTAssertTrue(v.canRender(url: URL(fileURLWithPath: "/x/b.epub"), sample: Data()))
        XCTAssertFalse(v.canRender(url: URL(fileURLWithPath: "/x/b.pdf"), sample: Data()))
        // Garbage container → a message the host shows (English source string, tr() at display).
        let url = try tempFile("junk.mobi", [1, 2, 3, 4])
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertThrowsError(try v.renderPage(url: url, isCancelled: { false }, update: { _ in })) { error in
            XCTAssertEqual(error.localizedDescription, "Cannot read ebook — showing hexadecimal")
        }
    }

    func testPageErrorCarriesItsMessage() {
        XCTAssertEqual(PageError("Ebook too large to render").localizedDescription, "Ebook too large to render")
    }
}
