import XCTest
@testable import double_finder

final class ListerSourceTests: XCTestCase {
    private func tempFile(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lister-src-\(UUID().uuidString)")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadMiddleAndClampAtEOF() throws {
        let url = try tempFile(Array(0..<100))
        let src = try XCTUnwrap(ListerSource(url: url))
        XCTAssertEqual(src.length, 100)
        XCTAssertEqual(src.read(offset: 10, count: 5), Data([10, 11, 12, 13, 14]))
        XCTAssertEqual(src.read(offset: 95, count: 50), Data([95, 96, 97, 98, 99])) // clamp
        XCTAssertEqual(src.read(offset: 100, count: 4), Data())  // at EOF → empty
        XCTAssertNil(src.read(offset: 101, count: 4))            // past EOF → nil
    }

    func testInitFailsOnMissingFile() {
        XCTAssertNil(ListerSource(url: URL(fileURLWithPath: "/nonexistent/xyz")))
    }

    func testDecoderCarriesSplitUTF8Character() {
        // "测" = E6 B5 8B; split it across two chunks.
        let bytes: [UInt8] = [0x61, 0xE6, 0xB5, 0x8B, 0x62]      // "a测b"
        var dec = TextChunkDecoder(encoding: .utf8)
        let s1 = dec.decode(Data(bytes[0..<2]), isFinal: false)   // "a" + partial
        XCTAssertEqual(dec.carryCount, 1)                         // 0xE6 held over (anchors rely on this)
        let s2 = dec.decode(Data(bytes[2...]), isFinal: true)
        XCTAssertEqual(s1 + s2, "a测b")
        XCTAssertFalse(dec.usedFallback)
    }

    func testDecoderFinalFlushFallsBackLatin1() {
        var dec = TextChunkDecoder(encoding: .utf8)
        let s = dec.decode(Data([0x61, 0xFF]), isFinal: true)     // invalid UTF-8 tail
        XCTAssertEqual(s.count, 2)                                // never returns empty
        XCTAssertTrue(dec.usedFallback)                           // fallback is reported, not silent
    }
}
