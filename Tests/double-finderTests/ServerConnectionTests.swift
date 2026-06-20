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
}
