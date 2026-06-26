import XCTest
@testable import double_finder

/// Verifies extractAll routing: 7z/zip → 7zz (when available), tarballs → libarchive
/// (one-step, NOT a leftover .tar). Builds archives with available tools.
final class ExtractRoutingTests: XCTestCase {
    private func sevenZip() -> String? {
        [FileManager.default.currentDirectoryPath + "/vendor/sevenzip/7zz",
         "/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z", "/opt/homebrew/bin/7za"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    private func mk(_ dir: String) throws {
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        try "alpha".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
        try "beta".write(toFile: dir + "/src/b.txt", atomically: true, encoding: .utf8)
    }

    func testTarGzExtractsRealFilesNotTar() throws {
        let dir = NSTemporaryDirectory() + "exr-tgz-\(ProcessInfo.processInfo.globallyUniqueString)"
        try mk(dir); defer { try? FileManager.default.removeItem(atPath: dir) }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["czf", dir + "/t.tar.gz", "-C", dir, "src"]
        try p.run(); p.waitUntilExit()
        let out = dir + "/out"; try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try ZipFS.extractAll(archivePath: dir + "/t.tar.gz", to: out)
        // MUST be the real files, NOT a leftover t.tar (the 7-Zip two-layer trap).
        XCTAssertEqual(try String(contentsOfFile: out + "/src/a.txt", encoding: .utf8), "alpha")
        XCTAssertEqual(try String(contentsOfFile: out + "/src/b.txt", encoding: .utf8), "beta")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out + "/t.tar"), "tarball must not extract to a .tar")
    }

    func testSevenZAndZipExtract() throws {
        guard let zz = sevenZip() else { throw XCTSkip("no 7z tool") }
        let dir = NSTemporaryDirectory() + "exr-7z-\(ProcessInfo.processInfo.globallyUniqueString)"
        try mk(dir); defer { try? FileManager.default.removeItem(atPath: dir) }
        for (ext, fmt) in [("7z", "-t7z"), ("zip", "-tzip")] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: zz)
            p.currentDirectoryURL = URL(fileURLWithPath: dir + "/src")
            p.arguments = ["a", fmt, dir + "/arc." + ext, "a.txt", "b.txt"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            let out = dir + "/out_" + ext
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try ZipFS.extractAll(archivePath: dir + "/arc." + ext, to: out)
            XCTAssertEqual(try String(contentsOfFile: out + "/a.txt", encoding: .utf8), "alpha", "\(ext)")
            XCTAssertEqual(try String(contentsOfFile: out + "/b.txt", encoding: .utf8), "beta", "\(ext)")
        }
    }
}
