import XCTest
@testable import double_finder

/// `Volumes.isEjectable` — which mounted volumes get an ⏏ Eject affordance.
final class VolumeEjectableTests: XCTestCase {

    func testBootVolumeNeverEjectable() {
        XCTAssertFalse(double_finder.Volumes.isEjectable(
            ejectable: false, removable: false, internalStorage: true, local: true, rootFS: true))
        // Even if macOS reported the boot volume as external, rootFS wins.
        XCTAssertFalse(double_finder.Volumes.isEjectable(
            ejectable: true, removable: true, internalStorage: false, local: true, rootFS: true))
    }

    func testInternalSecondaryVolumeNotEjectable() {
        XCTAssertFalse(double_finder.Volumes.isEjectable(
            ejectable: false, removable: false, internalStorage: true, local: true, rootFS: false))
    }

    func testUSBStickRemovable() {
        XCTAssertTrue(double_finder.Volumes.isEjectable(
            ejectable: false, removable: true, internalStorage: false, local: true, rootFS: false))
    }

    /// The case that motivated `internalStorage`: USB/Thunderbolt hard drives
    /// report ejectable=false AND removable=false — only internal=false catches them.
    func testExternalHardDriveNeitherEjectableNorRemovable() {
        XCTAssertTrue(double_finder.Volumes.isEjectable(
            ejectable: false, removable: false, internalStorage: false, local: true, rootFS: false))
    }

    func testMountedDMGEjectable() {
        XCTAssertTrue(double_finder.Volumes.isEjectable(
            ejectable: true, removable: false, internalStorage: nil, local: true, rootFS: false))
    }

    func testNetworkMountEjectable() {
        XCTAssertTrue(double_finder.Volumes.isEjectable(
            ejectable: false, removable: false, internalStorage: nil, local: false, rootFS: false))
    }

    /// nil resource values (unknown) must not make a volume ejectable.
    func testAllNilNotEjectable() {
        XCTAssertFalse(double_finder.Volumes.isEjectable(
            ejectable: nil, removable: nil, internalStorage: nil, local: nil, rootFS: nil))
    }
}
