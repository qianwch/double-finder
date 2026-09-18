import XCTest
@testable import double_finder

@MainActor
final class TransferPlannerTests: XCTestCase {
    private func sftp(_ host: String) -> RemoteSession {
        .sftp(SFTPConnection(host: host, user: "test"))
    }

    private func s3(_ host: String) -> RemoteSession {
        .s3(S3Connection(name: "Test", endpoint: "https://\(host)", region: "us-east-1",
                         bucket: "bucket", accessKey: "test", pathStyle: true), secret: "test")
    }

    func testDifferentSFTPHostsCannotFallBackToLocalDownload() {
        for move in [false, true] {
            XCTAssertThrowsError(try TransferPlanner.remoteProvider(from: sftp("source"),
                                                                    to: sftp("destination"), move: move)) {
                XCTAssertEqual($0 as? TransferRoutingError, .unsupportedRemotePair)
            }
        }
    }

    func testMixedRemoteBackendsAreRejectedInBothDirections() {
        let drive = PluginDriveSession(driveID: "plugin://test/fs", pluginID: "test", symbol: "folder",
                                       session: PluginKitTests.FakeSession())
        let device = AndroidDevice(vendor: "Test", product: "Phone", vendorID: 1, productID: 1,
                                   busLocation: 1, devNumber: 1, rawIndex: 0)
        let sessions: [RemoteSession] = [sftp("source"), s3("store"), .plugin(drive), .android(device, label: "Phone")]
        for (i, source) in sessions.enumerated() {
            for (j, destination) in sessions.enumerated() where i != j {
                for move in [false, true] {
                    XCTAssertThrowsError(try TransferPlanner.remoteProvider(from: source, to: destination, move: move)) {
                        XCTAssertEqual($0 as? TransferRoutingError, .unsupportedRemotePair)
                    }
                }
            }
        }
    }

    func testSameHostKeepsServerSideCopyAndMove() throws {
        for move in [false, true] {
            let provider = try XCTUnwrap(TransferPlanner.remoteProvider(from: sftp("host"), to: sftp("host"), move: move)
                as? SFTPSameHostProvider)
            XCTAssertEqual(provider.move, move)
        }
    }

    func testPluginTransfersRequireTheSameOpenSession() throws {
        let a = PluginDriveSession(driveID: "plugin://test/fs", pluginID: "test", symbol: "folder",
                                    session: PluginKitTests.FakeSession())
        // Even identical drive IDs do not identify the same live session.
        let b = PluginDriveSession(driveID: "plugin://test/fs", pluginID: "test", symbol: "folder",
                                    session: PluginKitTests.FakeSession())
        for move in [false, true] {
            let provider = try XCTUnwrap(TransferPlanner.remoteProvider(from: .plugin(a), to: .plugin(a), move: move)
                as? PluginTransferProvider)
            guard case .within(let actualMove) = provider.mode else {
                XCTFail("Same drive must transfer within the session"); continue
            }
            XCTAssertEqual(actualMove, move)
            XCTAssertThrowsError(try TransferPlanner.remoteProvider(from: .plugin(a), to: .plugin(b), move: move))
        }
    }

    func testAndroidTransfersRequireTheSameDevice() throws {
        let a = AndroidDevice(vendor: "Test", product: "Phone", vendorID: 1, productID: 1,
                              busLocation: 1, devNumber: 1, rawIndex: 0)
        let b = AndroidDevice(vendor: "Test", product: "Phone", vendorID: 1, productID: 1,
                              busLocation: 1, devNumber: 2, rawIndex: 1)
        for move in [false, true] {
            let provider = try XCTUnwrap(TransferPlanner.remoteProvider(from: .android(a, label: "One"),
                                                                         to: .android(a, label: "One"), move: move)
                as? AndroidSameDeviceProvider)
            XCTAssertEqual(provider.move, move)
            XCTAssertThrowsError(try TransferPlanner.remoteProvider(from: .android(a, label: "One"),
                                                                     to: .android(b, label: "Two"), move: move))
        }
    }

    func testS3RetainsSameStoreAndCrossStoreStrategies() throws {
        let same = try XCTUnwrap(TransferPlanner.remoteProvider(from: s3("one"), to: s3("one"), move: true)
            as? S3SameStoreProvider)
        XCTAssertTrue(same.move)
        for move in [false, true] {
            XCTAssertTrue(try TransferPlanner.remoteProvider(from: s3("one"), to: s3("two"), move: move)
                is S3CrossStoreProvider)
        }
    }

    func testLocalRemoteDirectionsArePreserved() throws {
        let download = try XCTUnwrap(TransferPlanner.remoteProvider(from: sftp("host"), to: nil, move: false)
            as? SFTPTransferProvider)
        XCTAssertEqual(download.direction, .download)
        let upload = try XCTUnwrap(TransferPlanner.remoteProvider(from: nil, to: sftp("host"), move: false)
            as? SFTPTransferProvider)
        XCTAssertEqual(upload.direction, .upload)
        XCTAssertNil(try TransferPlanner.remoteProvider(from: nil, to: nil, move: false))
    }
}
