import XCTest
@testable import double_finder

@MainActor
final class FileReferenceTests: XCTestCase {
    func testReferencesDistinguishEndpointsAndContainers() {
        let a = FileReference(endpointID: .remote("device/app-a"), path: "/Documents/file.txt")
        let b = FileReference(endpointID: .remote("device/app-b"), path: "/Documents/file.txt")
        let local = FileReference(endpointID: .local, path: "/Documents/file.txt")
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, local)
        XCTAssertEqual(a, FileReference(endpointID: .remote("device/app-a"), path: "/Documents/file.txt"))
    }

    func testReferencePreservesBackendPath() {
        let reference = FileReference(endpointID: .remote("store"), path: "/Bucket/A.zip/../Dir/")
        XCTAssertEqual(reference.path, "/Bucket/A.zip/../Dir/")
        XCTAssertNotEqual(reference, FileReference(endpointID: .remote("store"), path: "/bucket/Dir"))
    }

    func testPanelEndpointSnapshotDoesNotFollowLaterConnectionChange() {
        let panel = PanelState(path: "/")
        XCTAssertEqual(panel.fileEndpointID, .local)
        panel.remote = .sftp(SFTPConnection(host: "first", user: "u"))
        let captured = panel.fileEndpointID
        let resolve = { FileReference(endpointID: captured, path: "/file.txt") }
        panel.remote = .sftp(SFTPConnection(host: "second", user: "u"))
        XCTAssertEqual(resolve().endpointID, .remote("sftp://u@first:22"))
        XCTAssertEqual(panel.fileEndpointID, .remote("sftp://u@second:22"))
    }

    func testRemoteArchiveEndpointUsesArchiveConnection() {
        let archive = SFTPConnection(host: "archive-host", user: "reader")
        XCTAssertEqual(FileEndpointID(remote: nil, archiveConnection: archive),
                       .remote("sftp://reader@archive-host:22"))
        XCTAssertEqual(FileEndpointID(remote: .sftp(SFTPConnection(host: "other", user: "u")),
                                      archiveConnection: archive),
                       .remote("sftp://reader@archive-host:22"))
    }
}
