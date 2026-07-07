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

    func testGarbageNeverFails() {
        let garbage = Data((0..<200).map { _ in UInt8.random(in: 0...255) })
        let enc = EncodingDetector.detect(sample: garbage)
        // Whatever the detector picks (or the ISO-8859-1 fallback), it MUST decode the sample.
        XCTAssertNotNil(String(data: garbage, encoding: enc))
        XCTAssertEqual(EncodingDetector.detect(sample: Data()), .utf8)   // empty → utf8
    }
}
