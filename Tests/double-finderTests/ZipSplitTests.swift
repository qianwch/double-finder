import XCTest
@testable import double_finder

/// Functional test for split-archive (.001) browsing/extraction: the volumes
/// are written by the in-process 7-Zip engine and read back as one stream.
final class ZipSplitTests: XCTestCase {
    func testBrowseAndExtractSplit7z() throws {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "splitfs-\(ProcessInfo.processInfo.globallyUniqueString)"
        try fm.createDirectory(atPath: dir + "/src/sub", withIntermediateDirectories: true)
        try "alpha".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
        try "beta".write(toFile: dir + "/src/sub/b.txt", atomically: true, encoding: .utf8)
        // Incompressible random data so 7z genuinely splits into multiple volumes.
        let rnd = FileHandle(forReadingAtPath: "/dev/urandom")!
        let blob = rnd.readData(ofLength: 250 * 1024); rnd.closeFile()
        try blob.write(to: URL(fileURLWithPath: dir + "/src/big.bin"))
        defer { try? fm.removeItem(atPath: dir) }

        // Split into 100k volumes → docs.7z.001, .002, .003, …
        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: dir + "/docs.7z",
                                  level: 5, password: nil, volumeBytes: 100 * 1024)
        XCTAssertFalse(fm.fileExists(atPath: dir + "/docs.7z"), "a split pack must not leave the single file")
        XCTAssertTrue(fm.fileExists(atPath: dir + "/docs.7z.001"), "split .001 not created")
        XCTAssertTrue(fm.fileExists(atPath: dir + "/docs.7z.002"), "expected multiple volumes")

        // The .001 is enterable; the listing comes back through 7zz with sizes.
        XCTAssertTrue(FileItem.isArchiveFileName("docs.7z.001"))
        XCTAssertEqual(ZipFS.kind(of: dir + "/docs.7z.001"), .sevenZip)
        XCTAssertEqual(SplitVolumes.set(forFirstVolume: dir + "/docs.7z.001").count, 3)
        let entries = try ZipFS.entryDetails(archivePath: dir + "/docs.7z.001", kind: .unknown)
        let paths = Set(entries.map { $0.path })
        XCTAssertTrue(paths.contains("src/a.txt"), "missing entries; got \(paths)")
        XCTAssertTrue(paths.contains("src/sub/b.txt"))
        XCTAssertTrue(paths.contains("src/big.bin"))
        XCTAssertEqual(entries.first { $0.path == "src/big.bin" }?.size, 256000)

        // Extracting a single entry from the split set works, and — like the
        // libarchive path — the entry lands flat under its own name: copying
        // `src/a.txt` out of the archive must NOT recreate `src/` in the target.
        let out = dir + "/out"
        try ZipFS.extractEntry(archivePath: dir + "/docs.7z.001", entry: "src/a.txt", to: out, kind: .unknown)
        XCTAssertEqual(try String(contentsOfFile: out + "/a.txt", encoding: .utf8), "alpha")
        XCTAssertFalse(fm.fileExists(atPath: out + "/src"), "parent folder must not be recreated")
        XCTAssertFalse((try fm.contentsOfDirectory(atPath: out)).contains { $0.hasPrefix(".df-extract-") },
                       "scratch directory must be cleaned up")

        // A folder entry keeps its own subtree but still drops its parent path.
        let out2 = dir + "/out2"
        try ZipFS.extractEntry(archivePath: dir + "/docs.7z.001", entry: "src/sub", to: out2, kind: .unknown)
        XCTAssertEqual(try String(contentsOfFile: out2 + "/sub/b.txt", encoding: .utf8), "beta")
        XCTAssertFalse(fm.fileExists(atPath: out2 + "/src"))
    }

    /// An *incomplete* multi-volume set (the final volume — which holds the 7z
    /// end-header — is missing) must report a plain "can't open" error, NOT an
    /// encryption error. Regression: a missing volume used to be misread as a
    /// password-protected archive, so double-clicking it prompted for a password.
    func testIncompleteSplitArchiveReportsOpenErrorNotPassword() throws {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "splitbad-\(ProcessInfo.processInfo.globallyUniqueString)"
        try fm.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        let rnd = FileHandle(forReadingAtPath: "/dev/urandom")!
        let blob = rnd.readData(ofLength: 400 * 1024); rnd.closeFile()
        try blob.write(to: URL(fileURLWithPath: dir + "/src/big.bin"))
        defer { try? fm.removeItem(atPath: dir) }

        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: dir + "/docs.7z",
                                  level: 5, password: nil, volumeBytes: 100 * 1024)

        // Delete the last volume → the end-header is gone, so 7z can't open it.
        let vols = (try fm.contentsOfDirectory(atPath: dir))
            .filter { $0.hasPrefix("docs.7z.") }.sorted()
        XCTAssertGreaterThan(vols.count, 1, "expected multiple volumes")
        try fm.removeItem(atPath: dir + "/" + vols.last!)

        XCTAssertThrowsError(try ZipFS.entryDetails(archivePath: dir + "/docs.7z.001", kind: .unknown)) { error in
            XCTAssertFalse(error is ArchiveEncryptedError,
                           "incomplete split set must NOT be reported as encrypted (no password prompt)")
            XCTAssertTrue(error is ArchiveOpenError, "expected ArchiveOpenError, got \(error)")
        }
    }
}
