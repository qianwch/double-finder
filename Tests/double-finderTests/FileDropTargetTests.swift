import XCTest
@testable import double_finder

final class FileDropTargetTests: XCTestCase {

    // MARK: Fixtures

    private func dir(_ name: String, _ path: String) -> FileItem {
        FileItem(id: UUID(), name: name, path: path, isDirectory: true,
                 isArchive: false, size: 0, modified: Date(), isHidden: false,
                 isSymlink: false, permissions: "rwxr-xr-x")
    }

    private func file(_ name: String, _ path: String) -> FileItem {
        FileItem(id: UUID(), name: name, path: path, isDirectory: false,
                 isArchive: false, size: 10, modified: Date(), isHidden: false,
                 isSymlink: false, permissions: "rw-r--r--")
    }

    private let cwd = "/work"

    /// Row 0 是真正的 ".." 行（`parentEntry` 生成，path 已是父目录），
    /// row 1 文件夹，row 2 文件，row 3 是 .app bundle（目录但不可投放）。
    private var items: [FileItem] {
        [
            FileItem.parentEntry(for: "/work"),
            dir("docs", "/work/docs"),
            file("notes.txt", "/work/notes.txt"),
            dir("Mail.app", "/work/Mail.app"),
        ]
    }

    // MARK: dropDestinationDir

    func testFolderRowIsTheDestination() {
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 1, items: items, currentPath: cwd),
                       "/work/docs")
    }

    func testDotDotRowGoesToParent() {
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 0, items: items, currentPath: cwd),
                       "/")
    }

    func testDotDotAtVolumeRootStaysAtRoot() {
        let rootItems = [FileItem.parentEntry(for: "/")]
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 0, items: rootItems, currentPath: "/"),
                       "/")
    }

    func testFileRowFallsBackToCurrentDirectory() {
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 2, items: items, currentPath: cwd),
                       cwd)
    }

    /// .app/.framework 等 bundle 是目录，但往里投文件会破坏签名 —— 不作落点。
    func testPackageBundleIsNotADropTarget() {
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 3, items: items, currentPath: cwd),
                       cwd)
    }

    func testNilRowFallsBackToCurrentDirectory() {
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: nil, items: items, currentPath: cwd),
                       cwd)
    }

    func testOutOfRangeRowFallsBackToCurrentDirectory() {
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 99, items: items, currentPath: cwd),
                       cwd)
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: -1, items: items, currentPath: cwd),
                       cwd)
    }

    func testNestedFolderRowUsesItsOwnPath() {
        let nested = [dir("2026", "/work/docs/2026")]
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 0, items: nested,
                                                         currentPath: "/work/docs"),
                       "/work/docs/2026")
    }

    /// ".." 的落点必须来自 currentPath，而不是该行自己的 path ——
    /// 两者在生产中一致，这条用例把契约钉死，防止将来改用 item.path。
    func testDotDotUsesCurrentPathNotItemPath() {
        let bogus = [dir("..", "/somewhere/else")]
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 0, items: bogus,
                                                         currentPath: "/work/docs"),
                       "/work")
    }
}
