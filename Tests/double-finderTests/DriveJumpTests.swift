import XCTest
@testable import double_finder

final class DriveJumpTests: XCTestCase {
    // A tiny fake world: two volumes ("/" holding home, "/Volumes/USB") and a
    // set of directories that exist.
    private func resolve(volumePath: String,
                         lastPath: String? = nil,
                         otherPanelPath: String? = nil,
                         homePath: String = "/Users/me",
                         existing: Set<String>) -> String {
        DriveJump.destination(
            volumePath: volumePath,
            lastPath: lastPath,
            otherPanelPath: otherPanelPath,
            homePath: homePath,
            volumeOf: { path in
                path.hasPrefix("/Volumes/USB") ? "/Volumes/USB" : "/"
            },
            isDirectory: { existing.contains($0) })
    }

    func testLastVisitedDirectoryWins() {
        let dest = resolve(volumePath: "/Volumes/USB",
                           lastPath: "/Volumes/USB/photos",
                           otherPanelPath: "/Volumes/USB/music",
                           existing: ["/Volumes/USB/photos", "/Volumes/USB/music", "/Users/me"])
        XCTAssertEqual(dest, "/Volumes/USB/photos")
    }

    func testVanishedLastPathFallsThrough() {
        // Remembered dir was deleted → fall back to the other panel's dir.
        let dest = resolve(volumePath: "/Volumes/USB",
                           lastPath: "/Volumes/USB/gone",
                           otherPanelPath: "/Volumes/USB/music",
                           existing: ["/Volumes/USB/music"])
        XCTAssertEqual(dest, "/Volumes/USB/music")
    }

    func testOtherPanelSameVolume() {
        let dest = resolve(volumePath: "/Volumes/USB",
                           otherPanelPath: "/Volumes/USB/music",
                           existing: ["/Volumes/USB/music", "/Users/me"])
        XCTAssertEqual(dest, "/Volumes/USB/music")
    }

    func testOtherPanelOnDifferentVolumeIsIgnored() {
        // Other panel is on "/", target is the USB stick → root of the stick.
        let dest = resolve(volumePath: "/Volumes/USB",
                           otherPanelPath: "/Users/me/docs",
                           existing: ["/Users/me/docs", "/Users/me"])
        XCTAssertEqual(dest, "/Volumes/USB")
    }

    func testHomeVolumeFallsBackToHome() {
        let dest = resolve(volumePath: "/",
                           otherPanelPath: "/Volumes/USB/music",
                           existing: ["/Volumes/USB/music", "/Users/me"])
        XCTAssertEqual(dest, "/Users/me")
    }

    func testNoMemoryNoOtherNotHomeVolume() {
        let dest = resolve(volumePath: "/Volumes/USB",
                           existing: ["/Users/me"])
        XCTAssertEqual(dest, "/Volumes/USB")
    }

    func testStaleLastPathOnWrongVolumeIsIgnored() {
        // A remembered path that no longer belongs to the volume (remount under
        // a different name) must not be used even if the directory exists.
        let dest = resolve(volumePath: "/Volumes/USB",
                           lastPath: "/Users/me/docs",
                           existing: ["/Users/me/docs", "/Users/me"])
        XCTAssertEqual(dest, "/Volumes/USB")
    }

    func testLastPathPriorityOverHomeOnHomeVolume() {
        let dest = resolve(volumePath: "/",
                           lastPath: "/Users/me/projects",
                           existing: ["/Users/me/projects", "/Users/me"])
        XCTAssertEqual(dest, "/Users/me/projects")
    }
}
