import XCTest
@testable import double_finder

/// Encrypted-7z handling. libarchive cannot decrypt 7z at all, so these archives
/// go to the in-process 7-Zip engine. The regression these cover: the fallback
/// once reported "corrupt or incomplete" instead of "needs a password", so the
/// panel showed an error alert and backed out instead of prompting.
final class EncryptedArchiveTests: XCTestCase {

    private let password = "secret123"
    private var dir = ""

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "enc7z-\(ProcessInfo.processInfo.globallyUniqueString)"
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        try "alpha".write(toFile: dir + "/src/a.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        if !dir.isEmpty { try? FileManager.default.removeItem(atPath: dir) }
    }

    /// `headerEncrypted` (`-mhe=on`) hides the entry names too, so even *listing*
    /// needs the password — that is the case libarchive can't touch at all.
    private func makeArchive(headerEncrypted: Bool) throws -> String {
        let name = headerEncrypted ? "header.7z" : "data.7z"
        try SevenZipEngine.create(sources: [(dir + "/src", "src")], to: dir + "/" + name,
                                  level: 5, password: password, encryptHeaders: headerEncrypted)
        return dir + "/" + name
    }

    // MARK: - Listing (what double-clicking an archive in a panel does)

    /// With no password yet, the engine's open must report "encrypted", never
    /// "corrupt" — the panel keys its password prompt off that.
    func testHeaderEncryptedListingReportsEncryptedNotCorrupt() throws {
        let archive = try makeArchive(headerEncrypted: true)
        XCTAssertThrowsError(try ZipFS.entryPaths(archivePath: archive, kind: .sevenZip)) { err in
            XCTAssertTrue(err is ArchiveEncryptedError,
                          "expected a password prompt, got \(type(of: err)): \(err)")
        }
    }

    /// `listDirectory` goes through `entryDetails`, not `entryPaths` — the panel's
    /// actual path, so it needs its own guard.
    func testHeaderEncryptedEntryDetailsReportsEncryptedNotCorrupt() throws {
        let archive = try makeArchive(headerEncrypted: true)
        XCTAssertThrowsError(try ZipFS.entryDetails(archivePath: archive, kind: .sevenZip)) { err in
            XCTAssertTrue(err is ArchiveEncryptedError,
                          "expected a password prompt, got \(type(of: err)): \(err)")
        }
    }

    func testHeaderEncryptedListsWithCorrectPassword() throws {
        let archive = try makeArchive(headerEncrypted: true)
        let paths = try ZipFS.entryPaths(archivePath: archive, kind: .sevenZip, password: password)
        XCTAssertTrue(paths.contains { $0.hasSuffix("a.txt") }, "got \(paths)")

        // Real size/mtime, and the folder recognized as one — 7z entry paths have
        // no trailing slash, so a path-only listing would call "src" a 0-byte file.
        let entries = try ZipFS.entryDetails(archivePath: archive, kind: .sevenZip, password: password)
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("a.txt") && $0.size == 5 && !$0.isDir }, "got \(entries)")
        XCTAssertTrue(entries.contains { $0.path == "src" && $0.isDir }, "got \(entries)")
    }

    /// A wrong password must stay an `ArchiveEncryptedError` so the panel can
    /// re-prompt rather than claim the archive is broken.
    func testWrongPasswordStillReportsEncrypted() throws {
        let archive = try makeArchive(headerEncrypted: true)
        XCTAssertThrowsError(try ZipFS.entryPaths(archivePath: archive, kind: .sevenZip, password: "nope")) { err in
            XCTAssertTrue(err is ArchiveEncryptedError,
                          "expected a re-prompt, got \(type(of: err)): \(err)")
        }
    }

    // MARK: - Extraction

    func testHeaderEncryptedExtractWithoutPasswordReportsEncrypted() throws {
        let archive = try makeArchive(headerEncrypted: true)
        let out = dir + "/out1"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ZipFS.extractAll(archivePath: archive, to: out)) { err in
            XCTAssertTrue(err is ArchiveEncryptedError,
                          "expected a password prompt, got \(type(of: err)): \(err)")
        }
    }

    func testHeaderEncryptedExtractsWithCorrectPassword() throws {
        let archive = try makeArchive(headerEncrypted: true)
        let out = dir + "/out2"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try ZipFS.extractAll(archivePath: archive, to: out, password: password)
        XCTAssertEqual(try String(contentsOfFile: out + "/src/a.txt", encoding: .utf8), "alpha")
    }

    /// Data-only encryption leaves the names readable, so listing succeeds and
    /// only the extraction needs the password.
    func testDataEncryptedListsButExtractionNeedsPassword() throws {
        let archive = try makeArchive(headerEncrypted: false)
        let paths = try ZipFS.entryPaths(archivePath: archive, kind: .sevenZip)
        XCTAssertTrue(paths.contains { $0.hasSuffix("a.txt") }, "got \(paths)")

        let out = dir + "/out3"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ZipFS.extractAll(archivePath: archive, to: out)) { err in
            XCTAssertTrue(err is ArchiveEncryptedError,
                          "expected a password prompt, got \(type(of: err)): \(err)")
        }
        try ZipFS.extractAll(archivePath: archive, to: out, password: password)
        XCTAssertEqual(try String(contentsOfFile: out + "/src/a.txt", encoding: .utf8), "alpha")
    }
}
