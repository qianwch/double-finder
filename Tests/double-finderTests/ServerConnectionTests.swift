import XCTest
@testable import double_finder

final class ServerConnectionTests: XCTestCase {

    func testSMBConnectionDictRoundTrip() {
        let c = SMBConnection(name: "NAS", host: "qian-nas.local")
        XCTAssertEqual(SMBConnection(dict: c.dict), c)
        XCTAssertNil(SMBConnection(dict: ["name": "x"]))   // missing host
    }

    func testSFTPRoundTripAndKind() {
        let s = SFTPConnection(host: "10.0.0.1", user: "ubuntu", port: 2222,
                               keyPath: "~/.ssh/id_rsa", remotePath: "/home/ubuntu")
        let conn = ServerConnection.sftp(s)
        XCTAssertEqual(conn.kind, .sftp)
        let back = ServerConnection(dict: conn.dict)
        XCTAssertEqual(back, conn)
        XCTAssertEqual(conn.dict["kind"], "sftp")
    }

    func testS3RoundTripAndKind() {
        let s = S3Connection(name: "minio", endpoint: "https://m.local:9000",
                             region: "us-east-1", bucket: "data", accessKey: "AK", pathStyle: true)
        let conn = ServerConnection.s3(s)
        XCTAssertEqual(conn.kind, .s3)
        XCTAssertEqual(conn.name, "minio")
        XCTAssertEqual(ServerConnection(dict: conn.dict), conn)
    }

    func testSMBRoundTripAndKind() {
        let conn = ServerConnection.smb(SMBConnection(name: "NAS", host: "qian-nas.local"))
        XCTAssertEqual(conn.kind, .smb)
        XCTAssertEqual(conn.name, "NAS")
        XCTAssertEqual(ServerConnection(dict: conn.dict), conn)
    }

    func testInitRejectsUnknownKind() {
        XCTAssertNil(ServerConnection(dict: ["kind": "ftp", "host": "x"]))
        XCTAssertNil(ServerConnection(dict: ["host": "x"]))   // no kind
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "ServerConnTest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testStoreAddLoadDelete() {
        let d = freshDefaults()
        let a = ServerConnection.smb(SMBConnection(name: "NAS", host: "nas.local"))
        let b = ServerConnection.s3(S3Connection(name: "minio", endpoint: "https://m:9000",
                                                 region: "us-east-1", bucket: "", accessKey: "AK", pathStyle: true))
        ServerConnectionStore.add(a, defaults: d)
        ServerConnectionStore.add(b, defaults: d)
        XCTAssertEqual(ServerConnectionStore.load(defaults: d).count, 2)
        // add same name+kind replaces (no dupe)
        ServerConnectionStore.add(a, defaults: d)
        XCTAssertEqual(ServerConnectionStore.load(defaults: d).count, 2)
        ServerConnectionStore.delete(name: "NAS", kind: .smb, defaults: d)
        let left = ServerConnectionStore.load(defaults: d)
        XCTAssertEqual(left.count, 1)
        XCTAssertEqual(left.first?.kind, .s3)
    }

    func testMigrationFromLegacyKeys() {
        let d = freshDefaults()
        // legacy SFTPBookmarks (dict shape used by SFTPBookmark)
        d.set([["name": "srv", "host": "10.0.0.9", "port": "22", "user": "ubuntu",
                "key": "~/.ssh/id_rsa", "path": "/home/ubuntu"]], forKey: "SFTPBookmarks")
        // legacy S3Connections
        d.set([["name": "minio", "endpoint": "https://m:9000", "region": "us-east-1",
                "bucket": "data", "accessKey": "AK", "pathStyle": "1"]], forKey: "S3Connections")
        // legacy SMBBookmarks (array of smb:// url strings)
        d.set(["smb://qian-nas.local"], forKey: "SMBBookmarks")

        ServerConnectionStore.migrateIfNeeded(defaults: d)
        let conns = ServerConnectionStore.load(defaults: d)
        XCTAssertEqual(Set(conns.map { $0.kind }), Set([.sftp, .s3, .smb]))
        XCTAssertTrue(d.bool(forKey: "ServerConnectionsMigrated"))
        // idempotent: second call doesn't duplicate
        ServerConnectionStore.migrateIfNeeded(defaults: d)
        XCTAssertEqual(ServerConnectionStore.load(defaults: d).count, 3)
        // legacy keys preserved
        XCTAssertNotNil(d.array(forKey: "SFTPBookmarks"))
    }

    func testKindLabel() {
        XCTAssertEqual(ServerConnection.smb(SMBConnection(name: "n", host: "h")).kindLabel, "SMB")
        let s3 = ServerConnection.s3(S3Connection(name: "x", endpoint: "https://e", region: "r", bucket: "", accessKey: "a", pathStyle: true))
        XCTAssertEqual(s3.kindLabel, "S3")
        let sftp = ServerConnection.sftp(SFTPConnection(host: "h", user: "u"))
        XCTAssertEqual(sftp.kindLabel, "SFTP")
    }
}
