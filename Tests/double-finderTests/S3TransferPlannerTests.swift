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
}
