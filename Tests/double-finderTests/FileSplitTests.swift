import XCTest
@testable import double_finder

final class FileSplitTests: XCTestCase {

    // MARK: - Pure helpers

    func testParseSize() {
        XCTAssertEqual(FileSplit.parseSize("100 MB"), 100 << 20)
        XCTAssertEqual(FileSplit.parseSize("250m"), 250 << 20)
        XCTAssertEqual(FileSplit.parseSize("1g"), 1 << 30)
        XCTAssertEqual(FileSplit.parseSize("700 MB (CD)"), 700 << 20)
        XCTAssertEqual(FileSplit.parseSize("512"), 512)          // bare number = bytes
        XCTAssertNil(FileSplit.parseSize(""))
        XCTAssertNil(FileSplit.parseSize("abc"))
        XCTAssertNil(FileSplit.parseSize("No split"))
    }

    func testPartCount() {
        XCTAssertEqual(FileSplit.partCount(fileSize: 25, partSize: 10), 3)
        XCTAssertEqual(FileSplit.partCount(fileSize: 20, partSize: 10), 2)
        XCTAssertEqual(FileSplit.partCount(fileSize: 5, partSize: 10), 1)
        XCTAssertEqual(FileSplit.partCount(fileSize: 0, partSize: 10), 1)
        XCTAssertEqual(FileSplit.partCount(fileSize: 10, partSize: 0), 0)
    }

    func testPartName() {
        XCTAssertEqual(FileSplit.partName(base: "big.dat", index: 1), "big.dat.001")
        XCTAssertEqual(FileSplit.partName(base: "big.dat", index: 999), "big.dat.999")
        XCTAssertEqual(FileSplit.partName(base: "big.dat", index: 1000), "big.dat.1000")
    }

    func testCrcFileRoundTrip() {
        let text = FileSplit.crcFileContent(fileName: "movie.avi", size: 12345, crcHex: "cbf43926")
        XCTAssertTrue(text.contains("crc32=CBF43926"))           // uppercase on disk
        let info = FileSplit.parseCrcFile(text)
        XCTAssertEqual(info.fileName, "movie.avi")
        XCTAssertEqual(info.size, 12345)
        XCTAssertEqual(info.crcHex, "cbf43926")                  // normalized lowercase
        XCTAssertEqual(FileSplit.parseCrcFile("junk\nno equals"), FileSplit.CrcInfo())
    }

    // MARK: - Streaming IO

    private func makeDir() throws -> String {
        let dir = NSTemporaryDirectory() + "/split-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/out", withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func testSplitAndCombineRoundTrip() throws {
        let dir = try makeDir()
        let payload = Data((0..<25).map { UInt8($0) })
        try payload.write(to: URL(fileURLWithPath: dir + "/big.dat"))

        var reported: Int64 = 0
        let outputs = try FileSplit.split(path: dir + "/big.dat", destDir: dir + "/out",
                                          partSize: 10, onBytes: { reported += $0 })
        XCTAssertEqual(reported, 25)
        XCTAssertEqual(outputs.map { ($0 as NSString).lastPathComponent },
                       ["big.dat.001", "big.dat.002", "big.dat.003", "big.dat.crc"])
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: dir + "/out/big.dat.001")[.size] as? Int64, 10)
        XCTAssertEqual(try fm.attributesOfItem(atPath: dir + "/out/big.dat.003")[.size] as? Int64, 5)

        let parts = FileSplit.partsList(firstPart: dir + "/out/big.dat.001")
        XCTAssertEqual(parts.count, 3)
        let crcInfo = FileSplit.parseCrcFile(
            try String(contentsOfFile: dir + "/out/big.dat.crc", encoding: .utf8))
        XCTAssertEqual(crcInfo.fileName, "big.dat")
        XCTAssertEqual(crcInfo.size, 25)

        let combined = dir + "/combined.dat"
        _ = try FileSplit.combine(parts: parts, destPath: combined, expected: crcInfo)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: combined)), payload)
    }

    func testExactMultipleLeavesNoEmptyTrailingPart() throws {
        let dir = try makeDir()
        try Data(repeating: 7, count: 20).write(to: URL(fileURLWithPath: dir + "/f"))
        let outputs = try FileSplit.split(path: dir + "/f", destDir: dir + "/out", partSize: 10)
        XCTAssertEqual(outputs.count, 3)   // .001 + .002 + .crc — no empty .003
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/out/f.003"))
    }

    func testCombineMismatchThrows() throws {
        let dir = try makeDir()
        try Data(repeating: 1, count: 15).write(to: URL(fileURLWithPath: dir + "/f"))
        _ = try FileSplit.split(path: dir + "/f", destDir: dir + "/out", partSize: 10)
        // Corrupt part 2, keep sizes identical.
        try Data(repeating: 9, count: 5).write(to: URL(fileURLWithPath: dir + "/out/f.002"))
        let parts = FileSplit.partsList(firstPart: dir + "/out/f.001")
        let crcInfo = FileSplit.parseCrcFile(try String(contentsOfFile: dir + "/out/f.crc", encoding: .utf8))
        XCTAssertThrowsError(try FileSplit.combine(parts: parts, destPath: dir + "/rebuilt",
                                                   expected: crcInfo)) {
            XCTAssertTrue($0 is FileSplit.CombineMismatchError)
        }
    }

    func testSplitCancelThrows() throws {
        let dir = try makeDir()
        try Data(repeating: 1, count: 15).write(to: URL(fileURLWithPath: dir + "/f"))
        XCTAssertThrowsError(try FileSplit.split(path: dir + "/f", destDir: dir + "/out",
                                                 partSize: 10, shouldCancel: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testPartsListRequiresFirstPart() {
        XCTAssertTrue(FileSplit.partsList(firstPart: "/nonexistent/x.002").isEmpty)
        XCTAssertTrue(FileSplit.partsList(firstPart: "/nonexistent/x").isEmpty)
    }
}
