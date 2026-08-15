import XCTest
@testable import double_finder

final class FileDropTargetTests: XCTestCase {

    // MARK: - Fixtures

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

    // MARK: - dropDestinationDir

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

    // MARK: - 边界：以下四条钉死目前靠 NSString 语义成立的行为

    func testEmptyItemsFallsBackToCurrentDirectory() {
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 0, items: [], currentPath: cwd),
                       cwd)
    }

    /// currentPath 带尾斜杠时 ".." 仍要落到正确的父目录
    /// （命令行栏 / GoToFolder / 收藏项都可能存进带斜杠的路径）。
    func testTrailingSlashOnCurrentPathStillResolvesParent() {
        let rows = [FileItem.parentEntry(for: "/work")]
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 0, items: rows,
                                                         currentPath: "/work/"),
                       "/")
    }

    /// ".." 的判定看的是名字而非行号——分支视图/过滤列表里它未必在第 0 行。
    func testDotDotIsRecognizedAtAnyRow() {
        let rows = [dir("docs", "/work/docs"), FileItem.parentEntry(for: "/work")]
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 1, items: rows, currentPath: cwd),
                       "/")
    }

    /// 名字像 bundle 的普通目录也被当作 package 挡掉——扩展名判定是
    /// 刻意的近似，宁可少投放也不能往真 bundle 里灌文件。
    func testPlainFolderNamedLikeAPackageIsAlsoExcluded() {
        let rows = [dir("Notes.bundle", "/work/Notes.bundle")]
        XCTAssertEqual(FileDropTarget.dropDestinationDir(row: 0, items: rows, currentPath: cwd),
                       cwd)
    }
}
