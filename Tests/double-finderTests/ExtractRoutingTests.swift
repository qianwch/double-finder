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

    /// Windows-made zips without the UTF-8 flag store names in a legacy codepage
    /// (GBK here). The macOS 7zz has no Windows codepage tables and mangles such
    /// names, so extractAll must route these zips to libarchive (charset-detected).
    func testLegacyGBKZipExtractsCorrectNames() throws {
        let dir = NSTemporaryDirectory() + "exr-gbk-\(ProcessInfo.processInfo.globallyUniqueString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Hand-built stored zip: one entry "华为文档.txt" (GBK bytes, UTF-8 flag off).
        let name: [UInt8] = [0xbb, 0xaa, 0xce, 0xaa, 0xce, 0xc4, 0xb5, 0xb5, 0x2e, 0x74, 0x78, 0x74]
        let body = Array("hello".utf8)                 // crc32("hello") = 0x3610A686
        var zip = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { zip.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { zip.append(contentsOf: $0) } }
        // local file header
        u32(0x04034b50); u16(20); u16(0); u16(0); u16(0); u16(0)
        u32(0x3610A686); u32(UInt32(body.count)); u32(UInt32(body.count))
        u16(UInt16(name.count)); u16(0); zip.append(contentsOf: name); zip.append(contentsOf: body)
        let cdOffset = UInt32(zip.count)
        // central directory
        u32(0x02014b50); u16(20); u16(20); u16(0); u16(0); u16(0); u16(0)
        u32(0x3610A686); u32(UInt32(body.count)); u32(UInt32(body.count))
        u16(UInt16(name.count)); u16(0); u16(0); u16(0); u16(0); u32(0); u32(0)
        zip.append(contentsOf: name)
        let cdSize = UInt32(zip.count) - cdOffset
        // end of central directory
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cdOffset); u16(0)
        let zipPath = dir + "/gbk.zip"
        try zip.write(to: URL(fileURLWithPath: zipPath))

        XCTAssertTrue(LibArchive.hasLegacyEntryNames(archivePath: zipPath, password: nil))
        let out = dir + "/out"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try ZipFS.extractAll(archivePath: zipPath, to: out)
        XCTAssertEqual(try String(contentsOfFile: out + "/华为文档.txt", encoding: .utf8), "hello",
                       "GBK-named entry must land on disk with its correct UTF-8 name")
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
