import XCTest
@testable import double_finder

/// The app-global registry of open remote sessions ("drives" in the drive bar).
@MainActor
final class RemoteSessionStoreTests: XCTestCase {

    private let sftpA = SFTPConnection(host: "a.example.com", user: "u")
    private let s3A = S3Connection(name: "minio", endpoint: "https://s3.example.com",
                                   region: "us-east-1", bucket: "", accessKey: "AK", pathStyle: true)

    override func setUp() async throws { RemoteSessionStore.shared.removeAll() }
    override func tearDown() async throws { RemoteSessionStore.shared.removeAll() }

    func testIDIgnoresNonIdentityFields() {
        // Same host+user+port is the same SFTP session regardless of the
        // configured initial path / address-book name (mirrors sameHost).
        var a = sftpA
        var b = sftpA
        a.remotePath = "/tmp"; a.name = "prod"
        XCTAssertEqual(RemoteSession.sftp(a).id, RemoteSession.sftp(b).id)
        b.port = 2222
        XCTAssertNotEqual(RemoteSession.sftp(a).id, RemoteSession.sftp(b).id)

        // Same endpoint+accessKey is the same S3 service; bucket is just a start location.
        var s = s3A
        s.bucket = "other"
        XCTAssertEqual(RemoteSession.s3(s, secret: "x").id, RemoteSession.s3(s3A, secret: "y").id)
    }

    func testRegisterAppendsAndDedupes() {
        let store = RemoteSessionStore.shared
        store.register(.sftp(sftpA))
        store.register(.s3(s3A, secret: "sk"))
        XCTAssertEqual(store.sessions.count, 2)

        var again = sftpA
        again.remotePath = "/var"
        store.register(.sftp(again))
        XCTAssertEqual(store.sessions.count, 2, "re-connecting the same host must not add a second drive")

        // Re-registering an S3 service refreshes the stored secret in place.
        store.register(.s3(s3A, secret: "sk2"))
        XCTAssertEqual(store.sessions.count, 2)
        guard case .s3(_, let secret) = store.sessions[1] else { return XCTFail("expected s3 session") }
        XCTAssertEqual(secret, "sk2")
    }

    func testRemoveAndNotification() {
        let store = RemoteSessionStore.shared
        store.register(.sftp(sftpA))

        let exp = expectation(forNotification: RemoteSessionStore.didChange, object: store)
        store.remove(id: RemoteSession.sftp(sftpA).id)
        wait(for: [exp], timeout: 1)
        XCTAssertTrue(store.sessions.isEmpty)

        // Removing an unknown id is a silent no-op.
        store.remove(id: "sftp://nobody@nowhere:22")
        XCTAssertTrue(store.sessions.isEmpty)
    }
}
