import XCTest
@testable import double_finder

/// Dropping local files onto a remote panel goes through the upload provider;
/// the items handed to it are built from the on-disk paths.
@MainActor
final class DropRemoteTests: XCTestCase {
    func testLocalItemReflectsDisk() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("df-drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = (dir as NSString).appendingPathComponent("pack.zip")
        try Data(repeating: 0, count: 10).write(to: URL(fileURLWithPath: file))

        let f = try XCTUnwrap(MainViewController.localItem(at: file))
        XCTAssertEqual(f.name, "pack.zip")
        XCTAssertEqual(f.size, 10)
        XCTAssertFalse(f.isDirectory)
        XCTAssertTrue(f.isArchive)
        let d = try XCTUnwrap(MainViewController.localItem(at: dir))
        XCTAssertTrue(d.isDirectory)
        XCTAssertNil(MainViewController.localItem(at: dir + "/missing"))
    }

    func testUploadProviderForEveryBackendKind() {
        // The drop uses the session's upload provider — every kind has one.
        let session = PluginKitTests.FakeSession()
        let drive = PluginDriveSession(driveID: "plugin://p/fs", pluginID: "p", symbol: "s", session: session)
        XCTAssertTrue(RemoteSession.plugin(drive).transferProvider(download: false) is PluginTransferProvider)
        XCTAssertTrue(RemoteSession.sftp(SFTPConnection(host: "h", user: "u")).transferProvider(download: false) is SFTPTransferProvider)
    }
}
