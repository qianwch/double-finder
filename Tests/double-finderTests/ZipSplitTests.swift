import XCTest
@testable import double_finder

/// Functional test for split-archive (.001) browsing/extraction via 7zz.
/// Skips when no 7z-family tool is available on the machine.
final class ZipSplitTests: XCTestCase {
    private func anySevenZip() -> String? {
        let candidates = [
            FileManager.default.currentDirectoryPath + "/vendor/sevenzip/7zz",
            "/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z", "/opt/homebrew/bin/7za",
            "/usr/local/bin/7zz", "/usr/local/bin/7z", "/usr/local/bin/7za",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func testBrowseAndExtractSplit7z() throws {
        guard let tool = anySevenZip() else { throw XCTSkip("no 7z tool available") }
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
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool)
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.arguments = ["a", "-v100k", "docs.7z", "./src"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertTrue(fm.fileExists(atPath: dir + "/docs.7z.001"), "split .001 not created")
        XCTAssertTrue(fm.fileExists(atPath: dir + "/docs.7z.002"), "expected multiple volumes")

        // The .001 is enterable; the listing comes back through 7zz with sizes.
        XCTAssertTrue(FileItem.isArchiveFileName("docs.7z.001"))
        let entries = try ZipFS.entryDetails(archivePath: dir + "/docs.7z.001", kind: .unknown)
        let paths = Set(entries.map { $0.path })
        XCTAssertTrue(paths.contains("src/a.txt"), "missing entries; got \(paths)")
        XCTAssertTrue(paths.contains("src/sub/b.txt"))
        XCTAssertTrue(paths.contains("src/big.bin"))
        XCTAssertEqual(entries.first { $0.path == "src/big.bin" }?.size, 256000)

        // Extracting a single entry from the split set works.
        let out = dir + "/out"
        try ZipFS.extractEntry(archivePath: dir + "/docs.7z.001", entry: "src/a.txt", to: out, kind: .unknown)
        XCTAssertEqual(try String(contentsOfFile: out + "/src/a.txt", encoding: .utf8), "alpha")
    }
}
