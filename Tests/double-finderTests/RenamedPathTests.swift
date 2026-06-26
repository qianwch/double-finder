import XCTest
@testable import double_finder

/// Pure-logic tests for `PanelState.renamedPath` — the in-place rename used to
/// reflect a rename without a network re-list. The S3 folder cases (trailing
/// slash, bucket root) are the easy-to-get-wrong ones.
final class RenamedPathTests: XCTestCase {
    func testLocalFileKeepsParent() {
        XCTAssertEqual(
            PanelState.renamedPath(oldPath: "/Users/x/docs/a.txt", newName: "b.txt", isDirectory: false),
            "/Users/x/docs/b.txt")
    }

    func testS3FileInPrefix() {
        XCTAssertEqual(
            PanelState.renamedPath(oldPath: "/bucket/sub/old.txt", newName: "new.txt", isDirectory: false),
            "/bucket/sub/new.txt")
    }

    func testS3FileAtBucketRoot() {
        XCTAssertEqual(
            PanelState.renamedPath(oldPath: "/bucket/old.txt", newName: "new.txt", isDirectory: false),
            "/bucket/new.txt")
    }

    func testS3FolderKeepsTrailingSlash() {
        XCTAssertEqual(
            PanelState.renamedPath(oldPath: "/bucket/sub/oldfolder/", newName: "newfolder", isDirectory: true),
            "/bucket/sub/newfolder/")
    }

    func testS3FolderAtBucketRootKeepsTrailingSlash() {
        XCTAssertEqual(
            PanelState.renamedPath(oldPath: "/bucket/oldfolder/", newName: "newfolder", isDirectory: true),
            "/bucket/newfolder/")
    }

    func testLocalFolderHasNoTrailingSlash() {
        // Local dir paths have no trailing slash; the result mustn't grow one.
        XCTAssertEqual(
            PanelState.renamedPath(oldPath: "/Users/x/old", newName: "new", isDirectory: true),
            "/Users/x/new")
    }
}
