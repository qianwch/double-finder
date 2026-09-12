import XCTest
@testable import double_finder

final class ViewerModeChooserTests: XCTestCase {
    func testMediaExtensionsGoToPreview() {
        for ext in ["png", "JPG", "mp4", "pdf", "docx", "mov"] {
            XCTAssertEqual(ViewerModeChooser.choose(fileExtension: ext, sample: Data([1, 2])).mode,
                           .preview, ext)
        }
    }

    func testNULByteMeansHex() {
        let bin = Data([0x4D, 0x5A, 0x00, 0x01])
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "bin", sample: bin).mode, .hex)
    }

    func testUTF16BOMBeatsNULSniff() {
        // UTF-16 LE "AB" contains NULs but has a BOM → text.
        let d = Data([0xFF, 0xFE, 0x41, 0x00, 0x42, 0x00])
        let r = ViewerModeChooser.choose(fileExtension: "txt", sample: d)
        XCTAssertEqual(r.mode, .text)
        XCTAssertEqual(r.encoding, .utf16LittleEndian)
    }

    func testPlainTextAndEmpty() {
        let r = ViewerModeChooser.choose(fileExtension: "log", sample: "hi 中文\n".data(using: .utf8)!)
        XCTAssertEqual(r.mode, .text)
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "txt", sample: Data()).mode, .text)
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "txt", sample: nil).mode, .preview) // unreadable → QL keeps old behavior
    }

    func testNonUTF8GarbageWithoutNULOrBOMFallsBackToText() {
        // No BOM, no NUL, non-UTF-8 garbage → text with single-byte fallback encoding.
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "txt",
                                                 sample: Data([0xC0, 0xC1, 0xFE])).mode, .text)
    }

    /// Rendered pages are a PageViewerPlugin decision now (built-in
    /// MarkdownPreviewPlugin / EbookReaderPlugin): the chooser itself sees a
    /// markdown file as plain text WITH a detected encoding (what "1" shows),
    /// and an ebook container as Quick Look (epub) or hex (Kindle).
    func testMarkdownIsTextWithEncodingForTheChooser() {
        let r = ViewerModeChooser.choose(fileExtension: "md", sample: "# t".data(using: .utf8)!)
        XCTAssertEqual(r.mode, .text)
        XCTAssertNotNil(r.encoding)
        for ext in ["mmd", "puml", "plantuml", "MARKDOWN"] {
            XCTAssertEqual(ViewerModeChooser.choose(fileExtension: ext, sample: Data("graph TD".utf8)).mode, .text, ext)
        }
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "md", sample: Data([0x4D, 0x00])).mode, .hex)
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "md", sample: Data()).mode, .text)
    }

    func testEbookContainersWithoutThePluginGoToQuickLookOrHex() {
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "epub", sample: Data([0x50, 0x4B, 0x00])).mode, .preview)
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "azw3", sample: Data([0x00, 0x01])).mode, .hex)
    }

    func testLooksLikeText() {
        XCTAssertTrue(ViewerModeChooser.looksLikeText(Data()))
        XCTAssertTrue(ViewerModeChooser.looksLikeText(Data("abc".utf8)))
        XCTAssertFalse(ViewerModeChooser.looksLikeText(Data([0x41, 0x00])))
        XCTAssertTrue(ViewerModeChooser.looksLikeText(Data([0xFF, 0xFE, 0x41, 0x00])), "UTF-16 BOM beats NULs")
    }

    func testBinaryDotPumlStillGoesHex() {
        let r = ViewerModeChooser.choose(fileExtension: "puml", sample: Data([0x00, 0x01]))
        XCTAssertEqual(r.mode, .hex)            // NUL 嗅探优先于扩展名路由
    }
}
