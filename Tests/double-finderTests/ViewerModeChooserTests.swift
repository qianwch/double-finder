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

    func testMarkdownRoutesToPreviewKeepingEncoding() {
        let r = ViewerModeChooser.choose(fileExtension: "md", sample: "# t".data(using: .utf8)!)
        XCTAssertEqual(r.mode, .preview)
        XCTAssertNotNil(r.encoding)                       // encoding detection still runs (design §4.1)
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "MARKDOWN",
                                                sample: "x".data(using: .utf8)!).mode, .preview)
    }
    func testMarkdownWithNULStillSniffsToHex() {
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "md",
                                                sample: Data([0x4D, 0x00])).mode, .hex)
    }
    func testEmptyMarkdownStaysText() {
        XCTAssertEqual(ViewerModeChooser.choose(fileExtension: "md", sample: Data()).mode, .text)
    }
}
