import XCTest
@testable import double_finder

/// 7-Zip `-bsp1` progress-line parsing (pure logic).
final class SevenZipProgressTests: XCTestCase {
    func testParsesPercentLine() {
        XCTAssertEqual(SevenZip.lastPercent(in: " 12% + big.bin"), 12)
        XCTAssertEqual(SevenZip.lastPercent(in: "  0%"), 0)
        XCTAssertEqual(SevenZip.lastPercent(in: "100% + a"), 100)
    }

    func testPicksLastPercentInChunk() {
        // 7zz refreshes the progress line with \r — a read chunk can carry several.
        XCTAssertEqual(SevenZip.lastPercent(in: "  5% + a\r 23% + b\r 47% + c"), 47)
    }

    func testNoPercent() {
        XCTAssertNil(SevenZip.lastPercent(in: "7-Zip 23.01 (arm64)"))
        XCTAssertNil(SevenZip.lastPercent(in: ""))
        XCTAssertNil(SevenZip.lastPercent(in: "Compressing  big.bin"))
    }

    func testIgnoresPercentInFileNames() {
        // A trailing digit run directly before '%' is a progress token even when
        // file names appear around it; a bare "%" with no digits is not.
        XCTAssertEqual(SevenZip.lastPercent(in: " 42% + weird%name.txt"), 42)
        XCTAssertNil(SevenZip.lastPercent(in: "just a % sign"))
    }
}

/// Byte-progress + cancel hooks of archive creation.
final class PackProgressTests: XCTestCase {
    private var dir = ""

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "PackProgressTests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Two source files with known sizes (data is incompressible-ish random).
        var bytes = [UInt8](repeating: 0, count: 100_000)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        try Data(bytes).write(to: URL(fileURLWithPath: dir + "/a.bin"))
        try Data(bytes[0..<50_000]).write(to: URL(fileURLWithPath: dir + "/b.bin"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Collects progress deltas thread-safely (reporters run off the main thread).
    private final class Sum: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64 = 0
        func add(_ d: Int64) { lock.lock(); value += d; lock.unlock() }
        var total: Int64 { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testLibArchiveCreateReportsAllSourceBytes() throws {
        let out = dir + "/out.zip"
        let sum = Sum()
        try LibArchive.create(sources: [(dir + "/a.bin", "a.bin"), (dir + "/b.bin", "b.bin")],
                              to: out, format: .zip, level: 5, password: nil,
                              onBytes: { sum.add($0) })
        XCTAssertEqual(sum.total, 150_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
    }

    func testLibArchiveCreateCancels() {
        let out = dir + "/out.zip"
        XCTAssertThrowsError(
            try LibArchive.create(sources: [(dir + "/a.bin", "a.bin")],
                                  to: out, format: .zip, level: 5, password: nil,
                                  shouldCancel: { true })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testExternalSevenZipReportsFullTotal() async throws {
        try XCTSkipIf(SevenZip.resolve() == nil, "needs 7z/7zz for the external-7z path")
        let out = dir + "/out.7z"
        let sum = Sum()
        // .sevenZip prefers the external tool when present; progress comes from
        // -bsp1 percent lines and is topped up to the full total on success.
        try await LocalFS().createArchive(sources: [dir + "/a.bin", dir + "/b.bin"], to: out,
                                          format: .sevenZip, level: 5, password: nil,
                                          totalSourceBytes: 150_000,
                                          progress: { sum.add($0) })
        XCTAssertEqual(sum.total, 150_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out))
    }

    func testRemovePackOutputsSplit() throws {
        let base = dir + "/x.7z"
        for ext in ["001", "002", "010"] {
            FileManager.default.createFile(atPath: base + "." + ext, contents: Data([1]))
        }
        FileManager.default.createFile(atPath: dir + "/x.7z.txt", contents: Data([1]))  // not a volume
        LocalFS.removePackOutputs(archivePath: base, split: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + ".001"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + ".002"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base + ".010"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/x.7z.txt"))
    }

    func testRemovePackOutputsSingle() throws {
        let out = dir + "/y.zip"
        FileManager.default.createFile(atPath: out, contents: Data([1]))
        LocalFS.removePackOutputs(archivePath: out, split: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out))
    }
}
