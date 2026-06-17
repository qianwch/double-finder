import XCTest
@testable import double_finder

/// Pure-logic unit tests (no AppKit / UI). These cover the archive-related
/// helpers that drive a lot of the panel behavior and are easy to get wrong.
final class ArchiveLogicTests: XCTestCase {

    // MARK: FileItem.isArchiveFileName

    func testRecognizesCommonArchives() {
        XCTAssertTrue(FileItem.isArchiveFileName("photos.zip"))
        XCTAssertTrue(FileItem.isArchiveFileName("backup.7z"))
        XCTAssertTrue(FileItem.isArchiveFileName("source.tar"))
        XCTAssertTrue(FileItem.isArchiveFileName("app.ipa"))
    }

    func testRecognizesCompoundTarSuffixes() {
        XCTAssertTrue(FileItem.isArchiveFileName("logs.tar.gz"))
        XCTAssertTrue(FileItem.isArchiveFileName("logs.tar.bz2"))
        XCTAssertTrue(FileItem.isArchiveFileName("logs.tar.xz"))
        XCTAssertTrue(FileItem.isArchiveFileName("logs.tgz"))
    }

    func testIsCaseInsensitive() {
        XCTAssertTrue(FileItem.isArchiveFileName("PHOTOS.ZIP"))
        XCTAssertTrue(FileItem.isArchiveFileName("Backup.7Z"))
    }

    func testRejectsNonArchives() {
        XCTAssertFalse(FileItem.isArchiveFileName("readme.txt"))
        XCTAssertFalse(FileItem.isArchiveFileName("Makefile"))
        XCTAssertFalse(FileItem.isArchiveFileName("archive.zip.part"))
        XCTAssertFalse(FileItem.isArchiveFileName(""))
    }

    func testBareCompressorsAreBrowsable() {
        // Single-file compressors are treated as one-file archives.
        XCTAssertTrue(FileItem.isArchiveFileName("dump.sql.gz"))
        XCTAssertTrue(FileItem.isArchiveFileName("data.xz"))
        XCTAssertTrue(FileItem.isArchiveFileName("blob.zst"))
    }

    // MARK: ArchiveFormat

    func testArchiveFormatExtensionMatchesRawValue() {
        for fmt in ArchiveFormat.allCases {
            XCTAssertEqual(fmt.fileExtension, fmt.rawValue)
            XCTAssertFalse(fmt.displayName.isEmpty)
        }
    }

    func testOnlyZipAnd7zSupportEncryption() {
        let encrypting = ArchiveFormat.allCases.filter { $0.supportsEncryption }
        XCTAssertEqual(Set(encrypting), [.zip, .sevenZip])
        XCTAssertFalse(ArchiveFormat.tar.supportsEncryption)
        XCTAssertFalse(ArchiveFormat.tarGz.supportsEncryption)
    }

    // MARK: FileItem.parentEntry

    func testParentEntryPointsToContainingDirectory() {
        let parent = FileItem.parentEntry(for: "/Users/me/Documents")
        XCTAssertEqual(parent.name, "..")
        XCTAssertTrue(parent.isDirectory)
        XCTAssertEqual(parent.path, "/Users/me")
    }
}
