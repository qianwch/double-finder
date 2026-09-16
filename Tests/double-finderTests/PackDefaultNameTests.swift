import XCTest
@testable import double_finder

/// The Pack dialog's suggested archive name (Alt+F5). It must follow the
/// *source* side — packing into the other panel must not name the archive after
/// the destination folder.
final class PackDefaultNameTests: XCTestCase {

    func testMultipleItemsUseSourceFolderName() {
        let name = PackDefaultName.suggest(
            itemNames: [("a.txt", false), ("b.txt", false), ("sub", true)],
            sourceDir: "/Users/me/Downloads/report/提取结果")
        XCTAssertEqual(name, "提取结果")
    }

    func testSingleFileDropsExtension() {
        let name = PackDefaultName.suggest(itemNames: [("notes.tar.gz", false)],
                                           sourceDir: "/Users/me/Documents")
        XCTAssertEqual(name, "notes.tar")
    }

    func testSingleDirectoryKeepsFullName() {
        let name = PackDefaultName.suggest(itemNames: [("MetaERP 1.5.1", true)],
                                           sourceDir: "/Users/me/Documents")
        XCTAssertEqual(name, "MetaERP 1.5.1")
    }

    func testDisplayPathInNameIsReducedToLeaf() {
        // Search / branch listings put a relative display path in `name`.
        let name = PackDefaultName.suggest(itemNames: [("sub/dir/photo.png", false)],
                                           sourceDir: "/Users/me/Pictures")
        XCTAssertEqual(name, "photo")
    }

    func testRootSourceFallsBackToArchive() {
        let name = PackDefaultName.suggest(itemNames: [("bin", true), ("etc", true)],
                                           sourceDir: "/")
        XCTAssertEqual(name, "archive")
    }
}
