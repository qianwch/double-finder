import XCTest
@testable import double_finder

/// F5/F6 must refuse a transfer whose destination equals the source location:
/// copying/moving an item onto itself (dest dir == item's parent dir) would make
/// LocalFS's overwrite path delete the source first (data loss), and copying a
/// folder into itself/its own subfolder can never terminate sensibly.
final class SelfTransferGuardTests: XCTestCase {

    func testFileIntoOwnParentIsBlocked() {
        let blocked = FileOperation.selfTransferSources(["/a/b/f.txt"], destDir: "/a/b")
        XCTAssertEqual(blocked, ["/a/b/f.txt"])
    }

    func testTrailingSlashOnDestIsNormalized() {
        let blocked = FileOperation.selfTransferSources(["/a/b/f.txt"], destDir: "/a/b/")
        XCTAssertEqual(blocked, ["/a/b/f.txt"])
    }

    func testDifferentDirIsAllowed() {
        let blocked = FileOperation.selfTransferSources(["/a/b/f.txt"], destDir: "/a/c")
        XCTAssertTrue(blocked.isEmpty)
    }

    func testFolderIntoItselfIsBlocked() {
        let blocked = FileOperation.selfTransferSources(["/a/dir"], destDir: "/a/dir")
        XCTAssertEqual(blocked, ["/a/dir"])
    }

    func testFolderIntoOwnSubfolderIsBlocked() {
        let blocked = FileOperation.selfTransferSources(["/a/dir"], destDir: "/a/dir/sub/deeper")
        XCTAssertEqual(blocked, ["/a/dir"])
    }

    func testSiblingWithCommonNamePrefixIsAllowed() {
        // "/a/dir2" must not be treated as inside "/a/dir".
        let blocked = FileOperation.selfTransferSources(["/a/dir"], destDir: "/a/dir2")
        XCTAssertTrue(blocked.isEmpty)
    }

    func testMixedSelectionReturnsOnlyOffenders() {
        let blocked = FileOperation.selfTransferSources(
            ["/a/b/f.txt", "/a/c/g.txt", "/a/b/sub"], destDir: "/a/b")
        XCTAssertEqual(blocked, ["/a/b/f.txt", "/a/b/sub"])
    }

    func testS3StylePaths() {
        // Same-store S3 transfer uses /bucket/key paths; same rules apply.
        XCTAssertEqual(FileOperation.selfTransferSources(["/bucket/dir/o.bin"], destDir: "/bucket/dir"),
                       ["/bucket/dir/o.bin"])
        XCTAssertTrue(FileOperation.selfTransferSources(["/bucket/dir/o.bin"], destDir: "/bucket2/dir").isEmpty)
    }

    func testRootDestination() {
        XCTAssertEqual(FileOperation.selfTransferSources(["/f.txt"], destDir: "/"), ["/f.txt"])
        XCTAssertTrue(FileOperation.selfTransferSources(["/a/f.txt"], destDir: "/").isEmpty)
    }
}
