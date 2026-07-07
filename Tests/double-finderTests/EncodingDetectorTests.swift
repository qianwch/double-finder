import XCTest
@testable import double_finder

final class EncodingDetectorTests: XCTestCase {
    func testBOMs() {
        XCTAssertEqual(EncodingDetector.detect(sample: Data([0xEF, 0xBB, 0xBF, 0x61])), .utf8)
        XCTAssertEqual(EncodingDetector.detect(sample: Data([0xFF, 0xFE, 0x61, 0x00])), .utf16LittleEndian)
        XCTAssertEqual(EncodingDetector.detect(sample: Data([0xFE, 0xFF, 0x00, 0x61])), .utf16BigEndian)
    }

    func testASCIIAndUTF8Chinese() {
        let ascii = "hello world\n".data(using: .utf8)!
        XCTAssertEqual(String(data: ascii, encoding: EncodingDetector.detect(sample: ascii)), "hello world\n")
        let zh = "双面板文件管理器，复刻 Total Commander。\n".data(using: .utf8)!
        XCTAssertEqual(String(data: zh, encoding: EncodingDetector.detect(sample: zh)),
                       "双面板文件管理器，复刻 Total Commander。\n")
    }

    func testGB18030RoundTrip() throws {
        let text = "简体中文编码检测样本：文件管理器。\n"
        let gbk = try XCTUnwrap(text.data(using: EncodingDetector.gb18030))
        let detected = EncodingDetector.detect(sample: gbk)
        XCTAssertEqual(String(data: gbk, encoding: detected), text)
    }

    func testTruncatedTailDoesNotDemoteToFallback() throws {
        // The caller samples the first N bytes of a file; for CJK text that almost
        // always cuts a multi-byte character in half. The detector must trim the
        // incomplete tail during verification instead of falling back to ISO-8859-1.
        let zh = "双面板文件管理器，复刻 Total Commander。".data(using: .utf8)!
        XCTAssertEqual(EncodingDetector.detect(sample: zh.dropLast(1)), .utf8)

        // Same guarantee for GB18030: tail trimming keeps the truncated sample from
        // landing on any single-byte fallback (ISO-8859-1 or Windows-1252 — same class
        // of demotion this test guards against).
        let text = "简体中文编码检测样本：文件管理器。"
        let gbk = try XCTUnwrap(text.data(using: EncodingDetector.gb18030))
        let detected = EncodingDetector.detect(sample: gbk.dropLast(1))
        XCTAssertFalse([.isoLatin1, .windowsCP1252].contains(detected))
    }

    func testGarbageNeverFails() {
        var garbage = Data((0..<200).map { _ in UInt8.random(in: 0...255) })
        garbage[0] = 0x41   // never start with a BOM prefix (1/65536 flake otherwise)
        let enc = EncodingDetector.detect(sample: garbage)
        // Contract: the detected encoding strict-decodes the sample after trimming ≤4
        // trailing bytes (incomplete tails are carried over by TextChunkDecoder downstream).
        // The full-sample assertion below still holds for random garbage because the
        // single-byte fallback encodings accept any byte, so full-sample decoding is
        // guaranteed for garbage input.
        XCTAssertNotNil(String(data: garbage, encoding: enc))
        XCTAssertEqual(EncodingDetector.detect(sample: Data()), .utf8)   // empty → utf8
    }
}
