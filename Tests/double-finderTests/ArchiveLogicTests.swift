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

    // MARK: LibArchive — per-archive charset detection + decode

    // 华为MetaERP 1.5.1 产品文档 _1.5.1.hwics, GBK-encoded (no UTF-8 flag).
    private static let gbkName = Data([0xbb, 0xaa, 0xce, 0xaa, 0x4d, 0x65, 0x74, 0x61, 0x45, 0x52, 0x50,
                                       0x20, 0x31, 0x2e, 0x35, 0x2e, 0x31, 0x20, 0xb2, 0xfa, 0xc6, 0xb7,
                                       0xce, 0xc4, 0xb5, 0xb5, 0x20, 0x5f, 0x31, 0x2e, 0x35, 0x2e, 0x31,
                                       0x2e, 0x68, 0x77, 0x69, 0x63, 0x73])
    // テスト.txt, Shift-JIS-encoded.
    private static let sjisName = Data([0x83, 0x65, 0x83, 0x58, 0x83, 0x67, 0x2e, 0x74, 0x78, 0x74])

    func testDetectsGBKArchiveAndDecodes() {
        let enc = LibArchive.detectLegacyEncoding([Self.gbkName])
        XCTAssertNotNil(enc)
        XCTAssertEqual(LibArchive.decodeName(Self.gbkName, encoding: enc),
                       "华为MetaERP 1.5.1 产品文档 _1.5.1.hwics")
    }

    func testDetectsShiftJISArchiveAndDecodes() {
        // Detection adapts per-archive — a Japanese package is NOT forced to GBK.
        let enc = LibArchive.detectLegacyEncoding([Self.sjisName])
        XCTAssertNotNil(enc)
        XCTAssertEqual(LibArchive.decodeName(Self.sjisName, encoding: enc), "テスト.txt")
    }

    func testAllUTF8NamesNeedNoDetection() {
        // Pure-ASCII / UTF-8 names ⇒ no legacy charset, decode is identity.
        XCTAssertNil(LibArchive.detectLegacyEncoding([Data("folder/file.txt".utf8)]))
        XCTAssertEqual(LibArchive.decodeName(Data("产品文档.txt".utf8), encoding: nil), "产品文档.txt")
        XCTAssertEqual(LibArchive.decodeName(Data("folder/file.txt".utf8), encoding: nil), "folder/file.txt")
    }

    // MARK: FileItem.parentEntry

    func testParentEntryPointsToContainingDirectory() {
        let parent = FileItem.parentEntry(for: "/Users/me/Documents")
        XCTAssertEqual(parent.name, "..")
        XCTAssertTrue(parent.isDirectory)
        XCTAssertEqual(parent.path, "/Users/me")
    }
}
