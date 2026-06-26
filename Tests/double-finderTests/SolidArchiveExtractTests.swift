import XCTest
@testable import double_finder

/// Regression: extracting a single entry that is NOT the first one from a SOLID
/// 7z used to fail with "Truncated 7-Zip file body" — `archive_read_data_skip`
/// can't advance through a solid block, so the preceding entries must be
/// read+discarded to keep the decompressor in sync. Needs a 7z tool to BUILD a
/// solid archive (libarchive's 7z writer isn't solid); skips otherwise.
final class SolidArchiveExtractTests: XCTestCase {
    private func anySevenZip() -> String? {
        [FileManager.default.currentDirectoryPath + "/vendor/sevenzip/7zz",
         "/opt/homebrew/bin/7zz", "/opt/homebrew/bin/7z", "/opt/homebrew/bin/7za",
         "/usr/local/bin/7zz", "/usr/local/bin/7z"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func testExtractLaterEntryFromSolid7z() throws {
        guard let tool = anySevenZip() else { throw XCTSkip("no 7z tool available") }
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "solid-\(ProcessInfo.processInfo.globallyUniqueString)"
        try fm.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        // Three files with distinct, sizable, incompressible-ish content so the
        // solid block genuinely spans them.
        var contents: [String: Data] = [:]
        for (i, name) in ["a.bin", "b.bin", "c.bin"].enumerated() {
            var d = Data(count: 300_000)
            for j in 0..<d.count { d[j] = UInt8((j &* (i + 7)) & 0xFF) }
            contents[name] = d
            try d.write(to: URL(fileURLWithPath: dir + "/src/" + name))
        }
        // Build a SOLID 7z (7zz is solid by default).
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool)
        p.currentDirectoryURL = URL(fileURLWithPath: dir + "/src")
        p.arguments = ["a", "-t7z", dir + "/arc.7z", "a.bin", "b.bin", "c.bin"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        XCTAssertTrue(fm.fileExists(atPath: dir + "/arc.7z"))

        // Extract each entry on its own (incl. the 2nd and 3rd, which sit behind
        // earlier entries in the solid block) and verify byte-exact content.
        for name in ["a.bin", "b.bin", "c.bin"] {
            let out = dir + "/out_" + name
            try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
            try ZipFS.extractEntry(archivePath: dir + "/arc.7z", entry: name, to: out, kind: .sevenZip)
            let got = try Data(contentsOf: URL(fileURLWithPath: out + "/" + name))
            XCTAssertEqual(got, contents[name], "\(name) content mismatch after single-entry solid extract")
        }
    }
}
