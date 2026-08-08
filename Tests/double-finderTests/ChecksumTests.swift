import XCTest
@testable import double_finder

final class ChecksumTests: XCTestCase {

    // MARK: - Digests (known vectors)

    private func hex(of string: String, _ algo: ChecksumAlgorithm) throws -> String {
        let dir = NSTemporaryDirectory() + "/checksum-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/input"
        try string.write(toFile: path, atomically: true, encoding: .utf8)
        return try algo.hashFile(at: path)
    }

    func testKnownVectors() throws {
        XCTAssertEqual(try hex(of: "123456789", .crc32), "cbf43926")
        XCTAssertEqual(try hex(of: "abc", .md5), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(try hex(of: "abc", .sha1), "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(try hex(of: "abc", .sha256),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try hex(of: "", .crc32), "00000000")
        XCTAssertEqual(try hex(of: "", .md5), "d41d8cd98f00b204e9800998ecf8427e")
    }

    func testHashFileStreamsAndReportsBytes() throws {
        // >1MB so hashing spans multiple chunks.
        let blob = String(repeating: "0123456789abcdef", count: 100_000)   // 1.6 MB
        var reported: Int64 = 0
        let dir = NSTemporaryDirectory() + "/checksum-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/big"
        try blob.write(toFile: path, atomically: true, encoding: .utf8)
        let hex = try ChecksumAlgorithm.sha256.hashFile(at: path, onBytes: { reported += $0 })
        XCTAssertEqual(hex.count, 64)
        XCTAssertEqual(reported, Int64(blob.utf8.count))
    }

    func testHashFileCancel() throws {
        let dir = NSTemporaryDirectory() + "/checksum-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/f"
        try "data".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ChecksumAlgorithm.md5.hashFile(at: path, shouldCancel: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try ChecksumAlgorithm.md5.hashFile(at: "/nonexistent/x"))
    }

    // MARK: - Algorithm lookup

    func testAlgorithmForFileName() {
        XCTAssertEqual(ChecksumAlgorithm.forFile(named: "a.sfv"), .crc32)
        XCTAssertEqual(ChecksumAlgorithm.forFile(named: "a.MD5"), .md5)
        XCTAssertEqual(ChecksumAlgorithm.forFile(named: "a.sha256"), .sha256)
        XCTAssertNil(ChecksumAlgorithm.forFile(named: "a.txt"))
        XCTAssertNil(ChecksumAlgorithm.forFile(named: "sfv"))     // no extension
    }

    func testAlgorithmForDigestLength() {
        XCTAssertEqual(ChecksumAlgorithm.forDigestHexLength(8), .crc32)
        XCTAssertEqual(ChecksumAlgorithm.forDigestHexLength(32), .md5)
        XCTAssertEqual(ChecksumAlgorithm.forDigestHexLength(40), .sha1)
        XCTAssertEqual(ChecksumAlgorithm.forDigestHexLength(64), .sha256)
        XCTAssertEqual(ChecksumAlgorithm.forDigestHexLength(128), .sha512)
        XCTAssertNil(ChecksumAlgorithm.forDigestHexLength(10))
    }

    // MARK: - File format

    func testSerializeSFV() {
        let text = ChecksumFile.serialize(
            [ChecksumEntry(fileName: "a.txt", hexDigest: "cbf43926"),
             ChecksumEntry(fileName: "sub/b c.bin", hexDigest: "deadbeef")],
            algorithm: .crc32)
        XCTAssertTrue(text.hasPrefix("; "))                        // comment header
        XCTAssertTrue(text.contains("a.txt CBF43926"))             // uppercase hex
        XCTAssertTrue(text.contains("sub/b c.bin DEADBEEF"))       // name keeps spaces
    }

    func testSerializeMD5Style() {
        let text = ChecksumFile.serialize(
            [ChecksumEntry(fileName: "a.txt", hexDigest: "900150983CD24FB0D6963F7D28E17F72")],
            algorithm: .md5)
        XCTAssertEqual(text, "900150983cd24fb0d6963f7d28e17f72  a.txt\n")   // lowercase, two spaces
    }

    func testParseRoundTrip() {
        let entries = [ChecksumEntry(fileName: "a.txt", hexDigest: "cbf43926"),
                       ChecksumEntry(fileName: "b file.bin", hexDigest: "deadbeef")]
        let parsed = ChecksumFile.parse(ChecksumFile.serialize(entries, algorithm: .crc32))
        XCTAssertEqual(parsed, entries)

        let sha = [ChecksumEntry(fileName: "x y.dat",
                                 hexDigest: String(repeating: "ab", count: 32))]
        XCTAssertEqual(ChecksumFile.parse(ChecksumFile.serialize(sha, algorithm: .sha256)), sha)
    }

    func testParseCoreutilsVariants() {
        // Binary-mode marker, comments, blank lines, CRLF-ish trailing spaces.
        let text = """
        # md5sum output
        d41d8cd98f00b204e9800998ecf8427e *empty.bin

        900150983cd24fb0d6963f7d28e17f72  with space.txt
        """
        let parsed = ChecksumFile.parse(text)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0], ChecksumEntry(fileName: "empty.bin",
                                                hexDigest: "d41d8cd98f00b204e9800998ecf8427e"))
        XCTAssertEqual(parsed[1].fileName, "with space.txt")
    }

    func testParseSkipsGarbage() {
        let parsed = ChecksumFile.parse("""
        ; comment
        not a checksum line at all
        name-without-digest 12345
        zzzzzzzz name.txt
        """)
        // "zzzzzzzz" is 8 chars but not hex; "12345" is hex but not a digest length.
        XCTAssertTrue(parsed.isEmpty)
    }
}
