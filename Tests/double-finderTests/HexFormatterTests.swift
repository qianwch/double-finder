import XCTest
@testable import double_finder

final class HexFormatterTests: XCTestCase {
    func testFullRow() {
        let row = HexFormatter.row(offset: 0x10,
                                   bytes: [UInt8](0x41...0x50), digits: 8)
        XCTAssertEqual(row.offset, "00000010")
        XCTAssertEqual(row.hex, "41 42 43 44 45 46 47 48  49 4A 4B 4C 4D 4E 4F 50 ")
        XCTAssertEqual(row.ascii, "ABCDEFGHIJKLMNOP")
    }

    func testPartialTailRowPadsHexColumn() {
        let row = HexFormatter.row(offset: 0, bytes: [0x00, 0x7F, 0x20], digits: 8)
        XCTAssertEqual(row.hex.count, "41 42 43 44 45 46 47 48  49 4A 4B 4C 4D 4E 4F 50 ".count)
        XCTAssertEqual(row.ascii, ".. ")   // 0x00 → "."，0x7F → "."（不可打印），0x20 → 空格
    }

    func testNonPrintableDots() {
        let row = HexFormatter.row(offset: 0, bytes: [0x1F, 0x7F, 0x80, 0xFF], digits: 8)
        XCTAssertEqual(row.ascii, "....")
    }

    func testOffsetDigits() {
        XCTAssertEqual(HexFormatter.offsetDigits(fileLength: 100), 8)         // min 8
        // Width is sized to the LAST byte's offset (length-1 = 0xFFFFFFFFFF → 10 digits),
        // not to `length` itself.
        XCTAssertEqual(HexFormatter.offsetDigits(fileLength: 1 << 40), 10)
    }
}
