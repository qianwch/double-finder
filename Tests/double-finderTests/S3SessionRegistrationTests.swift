import XCTest
@testable import double_finder

@MainActor
final class S3SessionRegistrationTests: XCTestCase {
    private func connection(_ endpoint: String) -> S3Connection {
        S3Connection(name: "fixture", endpoint: endpoint, region: "test", bucket: "bucket",
                     accessKey: "fixture", pathStyle: true)
    }

    func testUnavailableS3NeverRegistersAndReturnsToLocal() async {
        let panel = PanelState(path: NSTemporaryDirectory())
        let conn = connection("http://127.0.0.1:1")
        let id = RemoteSession.s3(conn, secret: "fixture").id
        defer { RemoteSessionStore.shared.remove(id: id) }
        let failed = expectation(description: "connection failure")
        panel.onError = { _ in failed.fulfill() }
        panel.branchView = true
        panel.connectS3(conn, secret: "fixture", initialPath: "/bucket")
        XCTAssertFalse(panel.branchView)
        XCTAssertNil(RemoteSessionStore.shared.session(withID: id), "unverified connections must not appear in the drive bar")
        panel.leaveRemovedSessions(existingIDs: RemoteSessionStore.shared.ids)
        XCTAssertNotNil(panel.s3)
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertNil(panel.remote)
        XCTAssertEqual(panel.currentPath, NSTemporaryDirectory())
        XCTAssertNil(RemoteSessionStore.shared.session(withID: id))
    }

    func testSuccessfulS3RegistersOnlyAfterListingEvenFromBranchView() async throws {
        let server: LocalS3HTTPFixture
        do { server = try LocalS3HTTPFixture() }
        catch let error as NSError where error.domain == "S3Fixture" {
            throw XCTSkip("Loopback server unavailable in this environment: \(error)")
        }
        defer { server.stop() }
        try server.seed("hello.txt", Data("hello".utf8))
        let conn = connection(server.base.absoluteString)
        let id = RemoteSession.s3(conn, secret: "fixture").id
        defer { RemoteSessionStore.shared.remove(id: id) }
        let panel = PanelState(path: NSTemporaryDirectory())
        panel.onError = { error in XCTFail("S3 fixture failed: \(error)") }
        panel.branchView = true
        let loaded = expectation(description: "S3 listing committed")
        panel.onChange = {
            if panel.items.contains(where: { $0.name == "hello.txt" }) { loaded.fulfill() }
        }
        panel.connectS3(conn, secret: "fixture", initialPath: "/bucket")
        XCTAssertNil(RemoteSessionStore.shared.session(withID: id))
        XCTAssertFalse(panel.branchView)
        // Unrelated drive changes must not eject a connection being validated.
        panel.leaveRemovedSessions(existingIDs: RemoteSessionStore.shared.ids)
        XCTAssertNotNil(panel.s3)
        await fulfillment(of: [loaded], timeout: 10)
        XCTAssertNotNil(RemoteSessionStore.shared.session(withID: id))
    }

    func testFailedRetryDoesNotRemovePreviouslyRegisteredSession() async {
        let conn = connection("http://127.0.0.1:1")
        let session = RemoteSession.s3(conn, secret: "previous-secret")
        RemoteSessionStore.shared.register(session)
        defer { RemoteSessionStore.shared.remove(id: session.id) }
        let panel = PanelState(path: NSTemporaryDirectory())
        let failed = expectation(description: "retry failure")
        panel.onError = { _ in failed.fulfill() }
        panel.connectS3(conn, secret: "new-secret", initialPath: "/bucket")
        await fulfillment(of: [failed], timeout: 10)
        XCTAssertNil(panel.remote)
        guard case .s3(_, let secret)? = RemoteSessionStore.shared.session(withID: session.id) else {
            return XCTFail("retry must not eject a session held by another panel")
        }
        XCTAssertEqual(secret, "previous-secret")
    }
}
