import XCTest
@testable import double_finder

final class DuplicateScanTests: XCTestCase {
    private func file(_ path: String, size: Int64) -> DuplicateScan.FileInfo {
        DuplicateScan.FileInfo(path: path, name: (path as NSString).lastPathComponent, size: size)
    }

    func testEmptyOptionsGroupsNothing() {
        let files = [file("/a/x.txt", size: 1), file("/b/x.txt", size: 1)]
        let options = DuplicateScan.Options(sameName: false, sameSize: false, sameContent: false)
        XCTAssertTrue(DuplicateScan.group(files, options: options).isEmpty)
    }

    func testSameNameIsCaseInsensitive() {
        let files = [file("/a/Report.TXT", size: 5),
                     file("/b/report.txt", size: 9),
                     file("/c/other.txt", size: 5)]
        let options = DuplicateScan.Options(sameName: true, sameSize: false, sameContent: false)
        let groups = DuplicateScan.group(files, options: options)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].map(\.path), ["/a/Report.TXT", "/b/report.txt"])
    }

    func testSameNameAndSizeMustMatchBoth() {
        let files = [file("/a/x.txt", size: 5),
                     file("/b/x.txt", size: 5),
                     file("/c/x.txt", size: 6)]      // same name, different size
        let options = DuplicateScan.Options(sameName: true, sameSize: true, sameContent: false)
        let groups = DuplicateScan.group(files, options: options)
        XCTAssertEqual(groups, [[files[0], files[1]]])
    }

    func testSameSizeOnly() {
        let files = [file("/a/x.txt", size: 5),
                     file("/b/y.bin", size: 5),
                     file("/c/z.dat", size: 7)]
        let options = DuplicateScan.Options(sameName: false, sameSize: true, sameContent: false)
        let groups = DuplicateScan.group(files, options: options)
        XCTAssertEqual(groups, [[files[0], files[1]]])
    }

    func testSameContentHashesOnlyWithinSizeBuckets() {
        let files = [file("/a/1", size: 5), file("/b/2", size: 5),
                     file("/c/3", size: 5), file("/d/unique", size: 9)]
        var hashed: [String] = []
        let hash: (String) -> String? = { path in
            hashed.append(path)
            return path == "/c/3" ? "DIGEST-B" : "DIGEST-A"
        }
        let options = DuplicateScan.Options(sameName: false, sameSize: false, sameContent: true)
        let groups = DuplicateScan.group(files, options: options, hash: hash)
        XCTAssertEqual(groups, [[files[0], files[1]]])          // /c/3 differs, /d alone
        XCTAssertFalse(hashed.contains("/d/unique"))            // lone size never hashed
    }

    func testUnreadableFileDroppedFromContentGroups() {
        let files = [file("/a/1", size: 5), file("/b/2", size: 5), file("/c/3", size: 5)]
        let hash: (String) -> String? = { $0 == "/b/2" ? nil : "SAME" }
        let options = DuplicateScan.Options(sameName: false, sameSize: false, sameContent: true)
        let groups = DuplicateScan.group(files, options: options, hash: hash)
        XCTAssertEqual(groups, [[files[0], files[2]]])
    }

    func testGroupsAndMembersSortedByPath() {
        let files = [file("/z/x.txt", size: 1), file("/a/x.txt", size: 1),
                     file("/z/y.txt", size: 2), file("/a/y.txt", size: 2)]
        let options = DuplicateScan.Options(sameName: true, sameSize: true, sameContent: false)
        let groups = DuplicateScan.group(files, options: options)
        XCTAssertEqual(groups.map { $0.map(\.path) },
                       [["/a/x.txt", "/z/x.txt"], ["/a/y.txt", "/z/y.txt"]])
    }

    func testCancellationReturnsEmpty() {
        let files = [file("/a/1", size: 5), file("/b/2", size: 5)]
        let options = DuplicateScan.Options(sameName: false, sameSize: true, sameContent: false)
        XCTAssertTrue(DuplicateScan.group(files, options: options, isCancelled: { true }).isEmpty)
    }

    /// End-to-end against a real directory tree via findDuplicates.
    func testFindDuplicatesOnDisk() throws {
        let dir = NSTemporaryDirectory() + "/dup-tests-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        try "same-bytes".write(toFile: dir + "/one.txt", atomically: true, encoding: .utf8)
        try "same-bytes".write(toFile: dir + "/sub/two.txt", atomically: true, encoding: .utf8)
        try "different!".write(toFile: dir + "/three.txt", atomically: true, encoding: .utf8)

        let options = DuplicateScan.Options(sameName: false, sameSize: false, sameContent: true)
        let groups = FindFilesSheet.findDuplicates(start: dir, namePattern: "*",
                                                   subfolders: true, options: options)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].map(\.name)), ["one.txt", "two.txt"])

        // Without subfolders the pair is split across levels → no duplicates.
        let flat = FindFilesSheet.findDuplicates(start: dir, namePattern: "*",
                                                 subfolders: false, options: options)
        XCTAssertTrue(flat.isEmpty)
    }
}
