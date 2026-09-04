import XCTest
@testable import double_finder

/// The in-process 7-Zip engine (`Sources/CSevenZip` + `SevenZipEngine`): create,
/// list, extract, passwords, volumes, cancellation. No external tool involved —
/// these run on every machine, including the bare `swift test` on a dev box.
final class SevenZipEngineTests: XCTestCase {
    private var dir = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "szeng-\(ProcessInfo.processInfo.globallyUniqueString)"
        try fm.createDirectory(atPath: dir + "/src/sub/deep", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: dir + "/src/empty", withIntermediateDirectories: true)
        try "alpha".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
        try "beta".write(toFile: dir + "/src/sub/b.txt", atomically: true, encoding: .utf8)
        try "gamma".write(toFile: dir + "/src/sub/deep/c.txt", atomically: true, encoding: .utf8)
        try "中文 名字".write(toFile: dir + "/src/中文 名字.txt", atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: dir + "/src/link", withDestinationPath: "a.txt")
        var big = Data(count: 200_000)
        for i in 0..<big.count { big[i] = UInt8((i &* 31) & 0xFF) }
        try big.write(to: URL(fileURLWithPath: dir + "/src/big.bin"))
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
                             ofItemAtPath: dir + "/src/a.txt")
    }

    override func tearDown() {
        if !dir.isEmpty { try? fm.removeItem(atPath: dir) }
    }

    func testVersionIsKnown() {
        XCTAssertTrue(SevenZipEngine.version.hasPrefix("26."), SevenZipEngine.version)
    }

    func testRoundTripPreservesTreeNamesTimesAndLinks() throws {
        let arc = dir + "/t.7z"
        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: arc, level: 5, password: nil)

        let entries = try SevenZipEngine.list(archivePath: arc, password: nil)
        let byPath = Dictionary(uniqueKeysWithValues: entries.map { ($0.path, $0) })
        XCTAssertEqual(byPath["src/a.txt"]?.size, 5)
        XCTAssertEqual(byPath["src/a.txt"]?.mtime, Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertEqual(byPath["src/sub/deep"]?.isDir, true)
        XCTAssertEqual(byPath["src/empty"]?.isDir, true, "empty folders must be stored")
        XCTAssertNotNil(byPath["src/中文 名字.txt"], "non-ASCII names round-trip as UTF-8")

        let out = dir + "/out"
        try SevenZipEngine.extract(archivePath: arc, entry: nil, to: out, password: nil)
        XCTAssertEqual(try String(contentsOfFile: out + "/src/sub/deep/c.txt", encoding: .utf8), "gamma")
        XCTAssertEqual(try String(contentsOfFile: out + "/src/中文 名字.txt", encoding: .utf8), "中文 名字")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out + "/src/big.bin")),
                       try Data(contentsOf: URL(fileURLWithPath: dir + "/src/big.bin")))
        XCTAssertTrue(fm.fileExists(atPath: out + "/src/empty"))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: out + "/src/link"), "a.txt",
                       "symlinks are stored as links, not as copies of their target")
        let mtime = try fm.attributesOfItem(atPath: out + "/src/a.txt")[.modificationDate] as? Date
        XCTAssertEqual(mtime, Date(timeIntervalSince1970: 1_600_000_000))
    }

    /// A single entry pulled from a sub-folder lands flat under its own name —
    /// the panel's F5-from-inside-an-archive contract (no parent folders).
    func testSingleEntryExtractsFlat() throws {
        let arc = dir + "/t.7z"
        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: arc, level: 5, password: nil)
        let out = dir + "/out"
        try SevenZipEngine.extract(archivePath: arc, entry: "src/sub/deep/c.txt", to: out, password: nil)
        XCTAssertEqual(try String(contentsOfFile: out + "/c.txt", encoding: .utf8), "gamma")
        XCTAssertFalse(fm.fileExists(atPath: out + "/src"))

        let out2 = dir + "/out2"
        try SevenZipEngine.extract(archivePath: arc, entry: "src/sub", to: out2, password: nil)
        XCTAssertEqual(try String(contentsOfFile: out2 + "/sub/deep/c.txt", encoding: .utf8), "gamma")
        XCTAssertEqual(try String(contentsOfFile: out2 + "/sub/b.txt", encoding: .utf8), "beta")
        XCTAssertFalse(fm.fileExists(atPath: out2 + "/src"))
        XCTAssertFalse(fm.fileExists(atPath: out2 + "/a.txt"), "siblings outside the wanted folder must not land")
    }

    func testMissingEntryFails() throws {
        let arc = dir + "/t.7z"
        try SevenZipEngine.create(sources: [(dir + "/src/a.txt", "a.txt")], to: arc, level: 5, password: nil)
        XCTAssertThrowsError(try SevenZipEngine.extract(archivePath: arc, entry: "nope.txt", to: dir + "/out", password: nil))
    }

    func testDataEncryptionListsWithoutPasswordButExtractionNeedsIt() throws {
        let arc = dir + "/d.7z"
        try SevenZipEngine.create(sources: [(dir + "/src/a.txt", "a.txt")], to: arc,
                                  level: 5, password: "pw", encryptHeaders: false)
        XCTAssertEqual(try SevenZipEngine.list(archivePath: arc, password: nil).map { $0.path }, ["a.txt"])
        XCTAssertThrowsError(try SevenZipEngine.extract(archivePath: arc, entry: nil, to: dir + "/o1", password: nil)) {
            XCTAssertTrue($0 is ArchiveEncryptedError, "\($0)")
        }
        XCTAssertFalse(fm.fileExists(atPath: dir + "/o1/a.txt"), "no half-written file after a refused extract")
        XCTAssertThrowsError(try SevenZipEngine.extract(archivePath: arc, entry: nil, to: dir + "/o2", password: "wrong")) {
            XCTAssertTrue($0 is ArchiveEncryptedError, "\($0)")
        }
        try SevenZipEngine.extract(archivePath: arc, entry: nil, to: dir + "/o3", password: "pw")
        XCTAssertEqual(try String(contentsOfFile: dir + "/o3/a.txt", encoding: .utf8), "alpha")
    }

    func testHeaderEncryptionHidesNamesUntilThePasswordIsGiven() throws {
        let arc = dir + "/h.7z"
        try SevenZipEngine.create(sources: [(dir + "/src/a.txt", "a.txt")], to: arc,
                                  level: 5, password: "pw", encryptHeaders: true)
        XCTAssertThrowsError(try SevenZipEngine.list(archivePath: arc, password: nil)) {
            XCTAssertTrue($0 is ArchiveEncryptedError, "\($0)")
        }
        XCTAssertThrowsError(try SevenZipEngine.list(archivePath: arc, password: "wrong")) {
            XCTAssertTrue($0 is ArchiveEncryptedError, "\($0)")
        }
        XCTAssertEqual(try SevenZipEngine.list(archivePath: arc, password: "pw").map { $0.path }, ["a.txt"])
    }

    /// The whole panel flow on an encrypted 7z: libarchive gives up, the engine
    /// takes over, and `ZipFS` reports the right error type for the prompt.
    func testZipFSRoutesEncryptedSevenZipToTheEngine() throws {
        let arc = dir + "/h.7z"
        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: arc,
                                  level: 5, password: "pw", encryptHeaders: true)
        XCTAssertThrowsError(try ZipFS.entryDetails(archivePath: arc, kind: .sevenZip)) {
            XCTAssertTrue($0 is ArchiveEncryptedError, "\($0)")
        }
        let entries = try ZipFS.entryDetails(archivePath: arc, kind: .sevenZip, password: "pw")
        XCTAssertTrue(entries.contains { $0.path == "src/sub/b.txt" && $0.size == 4 })
        let out = dir + "/out"
        try ZipFS.extractEntry(archivePath: arc, entry: "src/sub", to: out, kind: .sevenZip, password: "pw")
        XCTAssertEqual(try String(contentsOfFile: out + "/sub/b.txt", encoding: .utf8), "beta")
    }

    func testVolumesAreReadBackByBothEngines() throws {
        let arc = dir + "/v.7z"
        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: arc, level: 0, password: nil,
                                  volumeBytes: 64 * 1024)
        let volumes = SplitVolumes.set(forFirstVolume: arc + ".001")
        XCTAssertGreaterThan(volumes.count, 2, "\(volumes)")
        for v in volumes.dropLast() {
            XCTAssertEqual(try fm.attributesOfItem(atPath: v)[.size] as? Int, 64 * 1024, "every volume but the last is full")
        }
        // The 7-Zip engine on the set…
        let viaEngine = try SevenZipEngine.list(archivePath: arc + ".001", password: nil).map { $0.path }.sorted()
        // …and libarchive through its concatenating reader, same result.
        let viaLibarchive = try LibArchive.listEntries(archivePath: arc + ".001", password: nil).map { $0.path }.sorted()
        XCTAssertEqual(viaEngine, viaLibarchive)
        XCTAssertTrue(viaEngine.contains("src/big.bin"))
        let out = dir + "/out"
        try LibArchive.extractItem(archivePath: arc + ".001", entry: "src/big.bin", to: out, password: nil)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out + "/big.bin")),
                       try Data(contentsOf: URL(fileURLWithPath: dir + "/src/big.bin")))
    }

    /// Encrypted + split is the combination that used to need 7zz twice over.
    func testEncryptedVolumesRoundTrip() throws {
        let arc = dir + "/ev.7z"
        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: arc, level: 1, password: "pw",
                                  encryptHeaders: true, volumeBytes: 64 * 1024)
        XCTAssertThrowsError(try ZipFS.entryDetails(archivePath: arc + ".001", kind: .unknown)) {
            XCTAssertTrue($0 is ArchiveEncryptedError, "\($0)")
        }
        let out = dir + "/out"
        try ZipFS.extractAll(archivePath: arc + ".001", to: out, password: "pw")
        XCTAssertEqual(try String(contentsOfFile: out + "/src/sub/b.txt", encoding: .utf8), "beta")
    }

    func testZipVolumesFromLibarchiveOpenAsOneArchive() throws {
        let arc = dir + "/v.zip"
        try LibArchive.create(sources: [(dir + "/src", "src")], to: arc, format: .zip, level: 0,
                              password: nil, volumeBytes: 64 * 1024)
        XCTAssertFalse(fm.fileExists(atPath: arc))
        let volumes = SplitVolumes.set(forFirstVolume: arc + ".001")
        XCTAssertGreaterThan(volumes.count, 2, "\(volumes)")
        XCTAssertEqual(ZipFS.kind(of: arc + ".001"), .zip)
        let entries = try ZipFS.entryDetails(archivePath: arc + ".001", kind: .unknown)
        XCTAssertTrue(entries.contains { $0.path == "src/big.bin" && $0.size == 200_000 }, "\(entries.map { $0.path })")
        let out = dir + "/out"
        try ZipFS.extractAll(archivePath: arc + ".001", to: out)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: out + "/src/big.bin")),
                       try Data(contentsOf: URL(fileURLWithPath: dir + "/src/big.bin")))
    }

    func testProgressAndCancellation() throws {
        let arc = dir + "/p.7z"
        var reported: Int64 = 0
        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: arc, level: 5, password: nil,
                                  onBytes: { reported += $0 })
        XCTAssertGreaterThanOrEqual(reported, 200_000, "progress must at least cover the big file")

        let cancelled = dir + "/c.7z"
        XCTAssertThrowsError(try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: cancelled,
                                                       level: 5, password: nil, shouldCancel: { true })) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
        XCTAssertFalse(fm.fileExists(atPath: cancelled), "a cancelled pack leaves no output")

        XCTAssertThrowsError(try SevenZipEngine.extract(archivePath: arc, entry: nil, to: dir + "/out",
                                                        password: nil, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError, "\($0)")
        }
    }

    func testCorruptArchiveIsAnOpenError() throws {
        let arc = dir + "/bad.7z"
        try Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0, 4, 1, 2, 3]).write(to: URL(fileURLWithPath: arc))
        XCTAssertThrowsError(try SevenZipEngine.list(archivePath: arc, password: nil)) {
            XCTAssertTrue($0 is ArchiveOpenError, "\($0)")
        }
    }
}
