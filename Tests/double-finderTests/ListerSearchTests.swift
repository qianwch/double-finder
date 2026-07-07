import XCTest
@testable import double_finder

final class ListerSearchTests: XCTestCase {
    /// In-memory reader standing in for ListerSource.read.
    private func reader(_ bytes: [UInt8]) -> (UInt64, Int) -> Data? {
        { offset, count in
            guard offset <= UInt64(bytes.count) else { return nil }
            let s = Int(offset), e = min(bytes.count, s + count)
            return Data(bytes[s..<e])
        }
    }

    func testCrossChunkBoundaryMatch() {
        // Pattern straddles the 4-byte chunk boundary.
        let bytes: [UInt8] = Array("xxxNEEDLExxx".utf8)
        let search = ListerSearch(pattern: Array("NEEDLE".utf8), foldCase: false)
        let hit = search.nextMatch(after: 0, fileLength: UInt64(bytes.count),
                                   chunkSize: 4, read: reader(bytes))
        XCTAssertEqual(hit, 3)
    }

    func testNextPrevSemanticsAndFirstPrevRefused() {
        let bytes: [UInt8] = Array("ab ab ab".utf8)          // "ab" at 0, 3, 6
        let s = ListerSearch(pattern: Array("ab".utf8), foldCase: false)
        let r = reader(bytes)
        XCTAssertEqual(s.nextMatch(after: 0, fileLength: 8, chunkSize: 3, read: r), 3)
        XCTAssertEqual(s.nextMatch(after: 3, fileLength: 8, chunkSize: 3, read: r), 6)
        XCTAssertNil(s.nextMatch(after: 6, fileLength: 8, chunkSize: 3, read: r))     // EOF
        XCTAssertEqual(s.previousMatch(before: 6), 3)        // cache-only
        XCTAssertEqual(s.previousMatch(before: 3), 0)
        XCTAssertNil(s.previousMatch(before: 0))             // first → refused (caller beeps)
        // Match at 0 was cached even though `after: 0` skipped past it.
        XCTAssertEqual(s.matches, [0, 3, 6])
    }

    func testOverlappingMatches() {
        let s = ListerSearch(pattern: Array("aa".utf8), foldCase: false)
        _ = s.nextMatch(after: 0, fileLength: 3, chunkSize: 2, read: reader(Array("aaa".utf8)))
        XCTAssertNil(s.nextMatch(after: 1, fileLength: 3, chunkSize: 2, read: reader(Array("aaa".utf8))))
        XCTAssertEqual(s.matches, [0, 1])
    }

    func testPatternEqualsChunkSize() {
        let bytes: [UInt8] = Array("zzabzz".utf8)
        let s = ListerSearch(pattern: Array("ab".utf8), foldCase: false)
        XCTAssertEqual(s.nextMatch(after: 0, fileLength: 6, chunkSize: 2, read: reader(bytes)), 2)
    }

    func testASCIICaseFolding() {
        let s = ListerSearch(pattern: Array("Error".utf8), foldCase: true)
        let bytes: [UInt8] = Array("xx ERROR xx error".utf8)
        let r = reader(bytes)
        XCTAssertEqual(s.nextMatch(after: 0, fileLength: UInt64(bytes.count), chunkSize: 5, read: r), 3)
        XCTAssertEqual(s.nextMatch(after: 3, fileLength: UInt64(bytes.count), chunkSize: 5, read: r), 12)
    }

    func testHexPatternParsing() {
        XCTAssertEqual(ListerSearch.parseHexPattern("4D 5A"), [0x4D, 0x5A])
        XCTAssertEqual(ListerSearch.parseHexPattern("4d5a"), [0x4D, 0x5A])
        XCTAssertNil(ListerSearch.parseHexPattern("4d5"))    // odd length
        XCTAssertNil(ListerSearch.parseHexPattern("gg"))     // non-hex
        XCTAssertNil(ListerSearch.parseHexPattern(""))       // empty
    }

    func testFoldCaseIsPartOfCacheKeySemantics() {
        // Same needle "AB" against "ab": foldCase true finds it (cached at offset 0,
        // even though nextMatch(after: 0) itself returns nil — strictly-after contract),
        // foldCase false finds nothing at all.
        let bytes: [UInt8] = Array("ab".utf8)
        let folding = ListerSearch(pattern: Array("AB".utf8), foldCase: true)
        XCTAssertNil(folding.nextMatch(after: 0, fileLength: 2, chunkSize: 2, read: reader(bytes)))
        XCTAssertEqual(folding.matches, [0])
        let strict = ListerSearch(pattern: Array("AB".utf8), foldCase: false)
        XCTAssertNil(strict.nextMatch(after: 0, fileLength: 2, chunkSize: 2, read: reader(bytes)))
        XCTAssertEqual(strict.matches, [])
    }

    func testMatchCacheCapTruncatesButKeepsForwardSemantics() {
        // 32 'a' bytes, pattern "a" (every offset matches), cap = 8.
        let bytes: [UInt8] = Array(repeating: 0x61, count: 32)
        let s = ListerSearch(pattern: [0x61], foldCase: false, maxCachedMatches: 8)
        let r = reader(bytes)
        var last: UInt64? = nil
        var hit = s.nextMatch(after: 0, fileLength: 32, chunkSize: 4, read: r)
        while let h = hit {
            last = h
            hit = s.nextMatch(after: h, fileLength: 32, chunkSize: 4, read: r)
        }
        XCTAssertEqual(last, 31)                 // still finds the very last match
        XCTAssertTrue(s.truncated)
        XCTAssertLessThanOrEqual(s.matches.count, 8 + 4) // halved at least once, not unbounded
    }

    func testParseHexPatternRejectsSignPrefix() {
        XCTAssertNil(ListerSearch.parseHexPattern("+f"))
    }
}
