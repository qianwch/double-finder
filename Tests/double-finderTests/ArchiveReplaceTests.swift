import XCTest
@testable import double_finder

/// LibArchive.rewriteReplacing — the F4 edit-inside-archive write-back.
final class ArchiveReplaceTests: XCTestCase {
    private var dir = ""

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "/replace-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/src/sub", withIntermediateDirectories: true)
        try "original-a".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
        try "original-b".write(toFile: dir + "/src/sub/b.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    private func makeArchive(format: ArchiveFormat, name: String) throws -> String {
        let path = dir + "/" + name
        try LibArchive.create(sources: [(dir + "/src/a.txt", "a.txt"),
                                        (dir + "/src/sub/b.txt", "sub/b.txt")],
                              to: path, format: format, level: 6, password: nil)
        return path
    }

    private func assertReplaced(_ archivePath: String) throws {
        try "EDITED CONTENT longer than before".write(toFile: dir + "/edited.txt",
                                                     atomically: true, encoding: .utf8)
        try LibArchive.rewriteReplacing(archivePath: archivePath, password: nil,
                                        entryPath: "sub/b.txt", withFile: dir + "/edited.txt")
        let out = dir + "/out-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try LibArchive.extractAll(archivePath: archivePath, to: out, password: nil)
        XCTAssertEqual(try String(contentsOfFile: out + "/sub/b.txt", encoding: .utf8),
                       "EDITED CONTENT longer than before")
        XCTAssertEqual(try String(contentsOfFile: out + "/a.txt", encoding: .utf8),
                       "original-a")   // untouched entry survives
    }

    func testReplaceInZip() throws {
        try assertReplaced(makeArchive(format: .zip, name: "t.zip"))
    }

    func testReplaceInTarGz() throws {
        try assertReplaced(makeArchive(format: .tarGz, name: "t.tar.gz"))
    }

    func testReplaceMissingEntryThrows() throws {
        let path = try makeArchive(format: .zip, name: "missing.zip")
        try "x".write(toFile: dir + "/edited.txt", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try LibArchive.rewriteReplacing(
            archivePath: path, password: nil,
            entryPath: "does/not/exist.txt", withFile: dir + "/edited.txt"))
        // Original archive untouched by the failed rewrite.
        let out = dir + "/out2"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try LibArchive.extractAll(archivePath: path, to: out, password: nil)
        XCTAssertEqual(try String(contentsOfFile: out + "/a.txt", encoding: .utf8), "original-a")
    }
}
