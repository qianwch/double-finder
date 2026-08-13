import XCTest
@testable import double_finder

/// `.app` and friends are directories, but each carries its own icon — the icon
/// cache keys them per path instead of sharing the one folder bitmap, and this
/// predicate is what makes that call.
final class PackageIconTests: XCTestCase {
    func testAppBundleIsAPackage() {
        XCTAssertTrue(FileItem.isPackageFileName("Claude.app"))
        XCTAssertTrue(FileItem.isPackageFileName("Amazon Kindle.app"))
        XCTAssertTrue(FileItem.isPackageFileName("优酷.app"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(FileItem.isPackageFileName("Xcode.APP"))
        XCTAssertTrue(FileItem.isPackageFileName("Some.Framework"))
    }

    func testOtherBundleKinds() {
        for name in ["Foo.framework", "Bar.bundle", "X.prefPane", "Y.qlgenerator",
                     "Z.saver", "W.workflow", "Notes.rtfd", "Deck.key"] {
            XCTAssertTrue(FileItem.isPackageFileName(name), name)
        }
    }

    func testPlainDirectoriesAndFilesAreNot() {
        for name in ["Documents", "my.app.backup", "notes.txt", "archive.zip",
                     "app", ".app", "photo.jpeg"] {
            XCTAssertFalse(FileItem.isPackageFileName(name), name)
        }
    }

    /// The whole point: a package must not land on the shared folder key, and a
    /// plain directory must.
    func testPackagesDoNotShareTheFolderIconKey() {
        XCTAssertNotEqual(FileItem.isPackageFileName("Claude.app"),
                          FileItem.isPackageFileName("Downloads"))
    }
}
