import XCTest
@testable import double_finder

final class SyncDirsJunkTests: XCTestCase {
    private func junk(_ rel: String) -> Bool { SyncDirsSheet.isJunk(rel: rel) }

    func testMetadataFiles() {
        XCTAssertTrue(junk(".DS_Store"))
        XCTAssertTrue(junk("sub/.DS_Store"))
        XCTAssertTrue(junk("Thumbs.db"))
        XCTAssertTrue(junk("desktop.ini"))
        XCTAssertTrue(junk("._resourcefork"))
        XCTAssertTrue(junk("photos/._cover.jpg"))
    }

    func testEditorAndDownloadTemp() {
        XCTAssertTrue(junk("notes.txt~"))
        XCTAssertTrue(junk("a.tmp"))
        XCTAssertTrue(junk("doc.swp"))
        XCTAssertTrue(junk("data.BAK"))          // case-insensitive extension
        XCTAssertTrue(junk("movie.part"))
    }

    func testSystemAndVCSAndBuildDirs() {
        XCTAssertTrue(junk(".git/config"))
        XCTAssertTrue(junk("repo/.git/HEAD"))
        XCTAssertTrue(junk(".svn/entries"))
        XCTAssertTrue(junk(".hg/store"))
        XCTAssertTrue(junk("node_modules/left-pad/index.js"))
        XCTAssertTrue(junk("front/bower_components/x/y.js"))
        XCTAssertTrue(junk("pkg/__pycache__/m.pyc"))
        XCTAssertTrue(junk(".venv/bin/python"))
        XCTAssertTrue(junk(".idea/workspace.xml"))
        XCTAssertTrue(junk("build/.gradle/x"))
        XCTAssertTrue(junk(".cache/blob"))
        XCTAssertTrue(junk(".Trashes/old"))
        XCTAssertTrue(junk(".Spotlight-V100/store"))
        XCTAssertTrue(junk("__MACOSX/._x"))
    }

    func testRealFilesAreNotJunk() {
        XCTAssertFalse(junk("report.pdf"))
        XCTAssertFalse(junk("src/main.swift"))
        XCTAssertFalse(junk("photos/cover.jpg"))
        XCTAssertFalse(junk("a/b/c/data.json"))
        XCTAssertFalse(junk("gitignore"))        // not ".git"
        XCTAssertFalse(junk("my_node_modules.txt"))
    }
}
