import XCTest
@testable import double_finder

final class S3TransferPlannerTests: XCTestCase {

    func testDownloadSingleFile() {
        // A single object "a/b/file.txt" downloaded into /dest → /dest/file.txt
        XCTAssertEqual(
            S3TransferPlanner.downloadLocalPath(key: "a/b/file.txt", folderKey: nil, destDir: "/dest"),
            "/dest/file.txt")
    }

    func testDownloadInsideFolderPreservesTree() {
        // Folder "a/M_BASE/" → keep structure under /dest/M_BASE/...
        XCTAssertEqual(
            S3TransferPlanner.downloadLocalPath(key: "a/M_BASE/dist/x.js", folderKey: "a/M_BASE/", destDir: "/dest"),
            "/dest/M_BASE/dist/x.js")
        XCTAssertEqual(
            S3TransferPlanner.downloadLocalPath(key: "a/M_BASE/y.txt", folderKey: "a/M_BASE/", destDir: "/dest"),
            "/dest/M_BASE/y.txt")
    }

    func testUploadSingleFile() {
        // local /home/u/file.txt uploaded to prefix "docs/" → key "docs/file.txt"
        XCTAssertEqual(
            S3TransferPlanner.uploadKey(localPath: "/home/u/file.txt", folderRoot: nil, destPrefix: "docs/"),
            "docs/file.txt")
    }

    func testUploadInsideFolderPreservesTree() {
        // local dir /home/u/proj (folderRoot) → key "docs/proj/src/a.js"
        XCTAssertEqual(
            S3TransferPlanner.uploadKey(localPath: "/home/u/proj/src/a.js", folderRoot: "/home/u/proj", destPrefix: "docs/"),
            "docs/proj/src/a.js")
    }

    func testUploadEmptyPrefix() {
        XCTAssertEqual(
            S3TransferPlanner.uploadKey(localPath: "/home/u/proj/a.js", folderRoot: "/home/u/proj", destPrefix: ""),
            "proj/a.js")
    }

    // MARK: - isWithin (path-traversal containment)

    func testIsWithinAcceptsNormalPaths() {
        XCTAssertTrue(S3TransferPlanner.isWithin("/dest/M_BASE/a.js", destDir: "/dest"))
        XCTAssertTrue(S3TransferPlanner.isWithin("/dest/file.txt", destDir: "/dest"))
    }

    func testIsWithinRejectsTraversal() {
        // downloadLocalPath of an escaping key must be caught by isWithin
        let escaped = S3TransferPlanner.downloadLocalPath(
            key: "M_BASE/../../../tmp/evil", folderKey: "M_BASE/", destDir: "/dest")
        XCTAssertFalse(S3TransferPlanner.isWithin(escaped, destDir: "/dest"))
        XCTAssertFalse(S3TransferPlanner.isWithin("/dest/../etc/x", destDir: "/dest"))
    }

    func testIsWithinDestDirExactMatch() {
        // destDir itself is accepted (edge case: key resolves exactly to root)
        XCTAssertTrue(S3TransferPlanner.isWithin("/dest", destDir: "/dest"))
    }

    func testIsWithinRejectsSiblingDir() {
        // /dest2/file must NOT be accepted when destDir is /dest
        XCTAssertFalse(S3TransferPlanner.isWithin("/dest2/file.txt", destDir: "/dest"))
    }
}
