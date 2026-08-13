import XCTest
@testable import double_finder

/// Pure-logic tests for the MTP virtual path model.
///
/// Real-device values are used on purpose: the probe against a Galaxy S25 Edge
/// reports a **Chinese** storage description ("内部存储") and a root entry with a
/// **leading space** (" 我的文件"), both of which the path model must survive.
final class MTPPathTests: XCTestCase {
    func testRootHasNoStorage() {
        let p = MTPPath("/")
        XCTAssertTrue(p.isDeviceRoot)
        XCTAssertNil(p.storageName)
        XCTAssertEqual(p.segments, [])
    }

    func testStorageRoot() {
        let p = MTPPath("/Internal storage")
        XCTAssertFalse(p.isDeviceRoot)
        XCTAssertEqual(p.storageName, "Internal storage")
        XCTAssertEqual(p.segments, [])
        XCTAssertTrue(p.isStorageRoot)
    }

    func testNestedPath() {
        let p = MTPPath("/Internal storage/DCIM/Camera/IMG_001.jpg")
        XCTAssertEqual(p.storageName, "Internal storage")
        XCTAssertEqual(p.segments, ["DCIM", "Camera", "IMG_001.jpg"])
        XCTAssertEqual(p.name, "IMG_001.jpg")
    }

    func testParent() {
        XCTAssertEqual(MTPPath("/SD card/a/b").parent?.raw, "/SD card/a")
        XCTAssertEqual(MTPPath("/SD card/a").parent?.raw, "/SD card")
        XCTAssertEqual(MTPPath("/SD card").parent?.raw, "/")
        XCTAssertNil(MTPPath("/").parent)
    }

    func testAppending() {
        XCTAssertEqual(MTPPath("/").appending("SD card").raw, "/SD card")
        XCTAssertEqual(MTPPath("/SD card").appending("DCIM").raw, "/SD card/DCIM")
    }

    /// A storage description containing "/" would break path splitting.
    func testStorageNameWithSlashIsSanitized() {
        XCTAssertEqual(MTPPath.sanitizeStorageName("USB/OTG"), "USB_OTG")
    }

    func testTrailingSlashAndDoubleSlashNormalized() {
        XCTAssertEqual(MTPPath("/SD card/DCIM/").raw, "/SD card/DCIM")
        XCTAssertEqual(MTPPath("//SD card//DCIM").segments, ["DCIM"])
    }

    /// Real device: the storage description comes back as Chinese text.
    func testChineseStorageName() {
        let p = MTPPath("/内部存储/DCIM/Camera")
        XCTAssertEqual(p.storageName, "内部存储")
        XCTAssertEqual(p.segments, ["DCIM", "Camera"])
        XCTAssertEqual(p.name, "Camera")
    }

    /// Real device: a root folder literally named " 我的文件" (leading space).
    /// Trimming components would make it unaddressable, so spaces must survive.
    func testLeadingSpaceInNameIsPreserved() {
        let p = MTPPath("/内部存储/ 我的文件/note.txt")
        XCTAssertEqual(p.segments, [" 我的文件", "note.txt"])
        XCTAssertEqual(p.parent?.raw, "/内部存储/ 我的文件")
        XCTAssertEqual(MTPPath("/内部存储").appending(" 我的文件").raw, "/内部存储/ 我的文件")
    }
}
