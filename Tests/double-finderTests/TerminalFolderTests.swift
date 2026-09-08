import XCTest
@testable import double_finder

/// `MainViewController.terminalFolder(for:in:)` — which folder "Open in
/// Terminal" starts in, given the cursor item.
@MainActor
final class TerminalFolderTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = NSTemporaryDirectory() + "df-terminal-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/repo.git/hooks", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/repo.git/HEAD", contents: Data("ref\n".utf8))
        try fm.createSymbolicLink(atPath: root + "/link", withDestinationPath: root + "/repo.git")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func item(_ rel: String, dir: Bool, symlink: Bool = false) -> FileItem {
        FileItem(id: UUID(), name: (rel as NSString).lastPathComponent, path: root + "/" + rel,
                 isDirectory: dir, isArchive: false, size: 0, modified: Date(), isHidden: false,
                 isSymlink: symlink, permissions: "rwxr-xr-x", depth: 2)
    }

    func testFolderUnderCursorIsEntered() {
        XCTAssertEqual(MainViewController.terminalFolder(for: item("repo.git", dir: true), in: root),
                       root + "/repo.git")
    }

    func testFileUnderCursorOpensItsParent() {
        XCTAssertEqual(MainViewController.terminalFolder(for: item("repo.git/HEAD", dir: false), in: root),
                       root + "/repo.git")
    }

    func testSymlinkToFolderIsEntered() {
        XCTAssertEqual(MainViewController.terminalFolder(for: item("link", dir: false, symlink: true), in: root),
                       root + "/link")
    }

    func testNoCursorOrParentEntryFallsBackToPanelFolder() {
        XCTAssertEqual(MainViewController.terminalFolder(for: nil, in: root), root)
        XCTAssertEqual(MainViewController.terminalFolder(for: FileItem.parentEntry(for: root), in: root), root)
    }

    func testDeletedFolderStillUsesItemFlag() {
        // Listing says folder but it vanished meanwhile: keep the folder path
        // rather than silently jumping to its parent.
        XCTAssertEqual(MainViewController.terminalFolder(for: item("gone", dir: true), in: root), root + "/gone")
    }
}
