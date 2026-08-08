import XCTest
@testable import double_finder

final class FileCodecTests: XCTestCase {

    // MARK: - Base64

    func testBase64RoundTripAndWrapping() {
        let data = Data((0..<200).map { UInt8($0) })
        let text = FileCodec.encodeBase64(data)
        for line in text.split(separator: "\n") {
            XCTAssertLessThanOrEqual(line.count, 76)
        }
        XCTAssertEqual(FileCodec.decodeBase64(text), data)
    }

    func testDecodeBase64ToleratesHeadersAndWhitespace() {
        let payload = Data("hello world".utf8)
        let text = """
        Content-Type: application/octet-stream
        Content-Transfer-Encoding: base64

          \(payload.base64EncodedString())
        """
        XCTAssertEqual(FileCodec.decodeBase64(text), payload)
        XCTAssertNil(FileCodec.decodeBase64("no base64 here!!!"))
    }

    // MARK: - UUEncode

    func testUUEncodeKnownVector() {
        // Classic example: "Cat" → "#0V%T" line.
        let text = FileCodec.uuencode(Data("Cat".utf8), fileName: "cat.txt")
        XCTAssertTrue(text.hasPrefix("begin 644 cat.txt\n"))
        XCTAssertTrue(text.contains("#0V%T\n"))
        XCTAssertTrue(text.hasSuffix("`\nend\n"))
    }

    func testUURoundTripVariousSizes() {
        for size in [0, 1, 2, 3, 44, 45, 46, 90, 137] {
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
            let text = FileCodec.uuencode(data, fileName: "blob.bin")
            let decoded = FileCodec.uudecode(text)
            XCTAssertEqual(decoded?.fileName, "blob.bin", "size \(size)")
            XCTAssertEqual(decoded?.data, data, "size \(size)")
        }
    }

    func testUUDecodeToleratesJunkAroundBody() {
        let text = "From: someone\n\n" +
            FileCodec.uuencode(Data("payload".utf8), fileName: "p.txt") +
            "trailing noise\n"
        let decoded = FileCodec.uudecode(text)
        XCTAssertEqual(decoded?.data, Data("payload".utf8))
    }

    func testUUDecodeRejectsMissingBegin() {
        XCTAssertNil(FileCodec.uudecode("#0V%T\n`\nend\n"))
    }

    // MARK: - Detection

    func testDetect() {
        XCTAssertEqual(FileCodec.detect("begin 644 x\n`\nend\n"), .uuencode)
        XCTAssertEqual(FileCodec.detect("aGVsbG8=\n"), .base64)
    }
}
