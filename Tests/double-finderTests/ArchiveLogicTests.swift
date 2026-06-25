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

    // MARK: split archives (.001 first volume)

    func testSplitArchiveFirstVolumeIsEnterable() {
        // Only the .001 of an archive volume set is enterable.
        XCTAssertTrue(FileItem.isArchiveFileName("docs.7z.001"))
        XCTAssertTrue(FileItem.isArchiveFileName("data.zip.001"))
        XCTAssertTrue(FileItem.isArchiveFileName("logs.tar.gz.001"))
        XCTAssertEqual(FileItem.splitArchiveFirstPartBase("docs.7z.001"), "docs.7z")
        XCTAssertEqual(FileItem.splitArchiveFirstPartBase("logs.tar.gz.001"), "logs.tar.gz")
    }

    func testNonFirstAndNonArchiveVolumesAreNotEnterable() {
        XCTAssertFalse(FileItem.isArchiveFileName("docs.7z.002"))   // continuation volume
        XCTAssertFalse(FileItem.isArchiveFileName("docs.7z.003"))
        XCTAssertFalse(FileItem.isArchiveFileName("movie.001"))     // base ".001" but not an archive name
        XCTAssertNil(FileItem.splitArchiveFirstPartBase("docs.7z.002"))
        XCTAssertNil(FileItem.splitArchiveFirstPartBase("movie.001"))
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

    // MARK: FileColumnLayout — Name divider resize (trade with first optional)

    func testNameRightEdgeIsAResizeDivider() {
        let l = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size", "date"], widths: [:])
        // The divider at Name's right edge must be reported as the "name" divider.
        XCTAssertEqual(l.resizeDivider(atX: l.nameWidth, tolerance: 4), "name")
    }

    func testShrinkingFirstOptionalWidensName() {
        let wide = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size", "date"],
                                    widths: ["size": 80])
        let narrow = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size", "date"],
                                      widths: ["size": 50])
        // Name absorbs the 30pt the first optional gave up — the trade the Name
        // divider performs. Total stays at the view width (no horizontal scroll).
        XCTAssertEqual(narrow.nameWidth - wide.nameWidth, 30, accuracy: 0.01)
    }

    func testTradingTwoOptionalsKeepsNameWidthAndMovesDivider() {
        // Dragging the size|date divider trades width between them only: size +30,
        // date −30. Name (and every other column) must stay put, and the divider
        // (size's right edge) must move right by exactly the traded 30pt — i.e.
        // the grabbed edge follows the cursor, not the opposite side.
        let before = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size", "date"],
                                      widths: ["size": 80, "date": 120])
        let after = FileColumnLayout(totalWidth: 600, visibleOptionalIDs: ["size", "date"],
                                     widths: ["size": 110, "date": 90])
        XCTAssertEqual(before.nameWidth, after.nameWidth, accuracy: 0.01)
        let dBefore = before.xRange(of: "size")!.upperBound
        let dAfter = after.xRange(of: "size")!.upperBound
        XCTAssertEqual(dAfter - dBefore, 30, accuracy: 0.01)
    }

    func testNameStaysAtLeastMinimum() {
        // Optionals wider than the view clamp Name to its 120 floor.
        let l = FileColumnLayout(totalWidth: 200, visibleOptionalIDs: ["size", "date"],
                                 widths: ["size": 130, "date": 130])
        XCTAssertEqual(l.nameWidth, 120, accuracy: 0.01)
    }

    // MARK: FileItem.parentEntry

    func testParentEntryPointsToContainingDirectory() {
        let parent = FileItem.parentEntry(for: "/Users/me/Documents")
        XCTAssertEqual(parent.name, "..")
        XCTAssertTrue(parent.isDirectory)
        XCTAssertEqual(parent.path, "/Users/me")
    }
}
