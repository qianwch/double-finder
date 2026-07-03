import XCTest
@testable import double_finder

/// Switching a panel between remote backends must fully leave the previous
/// session: connecting SFTP while on S3 (and vice versa) may not leave both
/// `sftp` and `s3` set, otherwise every `s3 != nil` check (drive bar label,
/// delete/transfer provider routing, rename) misroutes the SFTP path to S3.
@MainActor
final class RemoteSessionSwitchTests: XCTestCase {

    private let sftpConn = SFTPConnection(host: "h", user: "u")
    private let s3Connection = S3Connection(name: "n", endpoint: "https://s3.example.com",
                                            region: "us-east-1", bucket: "b",
                                            accessKey: "AK", pathStyle: true)

    func testConnectSFTPWhileOnS3ClearsS3Session() {
        let p = PanelState(path: "/Users/me")
        p.connectS3(s3Connection, secret: "sk", initialPath: "/b")
        XCTAssertNotNil(p.s3)

        p.connectSFTP(sftpConn, initialPath: "/home/ubuntu")

        XCTAssertNil(p.s3, "connecting SFTP must drop the previous S3 session")
        XCTAssertEqual(p.sftp, sftpConn)
        XCTAssertTrue(p.fs is SFTPFS)
        XCTAssertEqual(p.currentPath, "/home/ubuntu")
    }

    // MARK: - Multi-session drive switching

    func testConnectRegistersSessionInGlobalStore() {
        RemoteSessionStore.shared.removeAll()
        let p = PanelState(path: "/Users/me")
        p.connectSFTP(sftpConn, initialPath: "/home/ubuntu")
        p.connectS3(s3Connection, secret: "sk", initialPath: "/b")
        XCTAssertEqual(RemoteSessionStore.shared.sessions.count, 2,
                       "both remotes stay registered as drives after switching")
    }

    func testEnterSessionRestoresLastBrowsedPath() {
        RemoteSessionStore.shared.removeAll()
        let p = PanelState(path: "/Users/me")
        p.connectSFTP(sftpConn, initialPath: "/home/ubuntu")
        p.navigate(to: "/home/ubuntu/docs")
        p.connectS3(s3Connection, secret: "sk", initialPath: "/b")
        p.navigate(to: "/b/photos")

        p.enterSession(.sftp(sftpConn))
        XCTAssertEqual(p.currentPath, "/home/ubuntu/docs", "switching back restores the SFTP path")
        XCTAssertNil(p.s3)

        p.enterSession(.s3(s3Connection, secret: "sk"))
        XCTAssertEqual(p.currentPath, "/b/photos", "switching back restores the S3 path")
        XCTAssertNil(p.sftp)
    }

    func testEnterActiveSessionGoesToRoot() {
        let p = PanelState(path: "/Users/me")
        p.connectSFTP(sftpConn, initialPath: "/home/ubuntu")
        p.navigate(to: "/home/ubuntu/docs")
        p.enterSession(.sftp(sftpConn))
        XCTAssertEqual(p.currentPath, "/", "re-clicking the active drive goes to its root")
    }

    func testEnterSessionFirstTimeInThisPanelGoesToRoot() {
        let p = PanelState(path: "/Users/me")
        p.enterSession(.s3(s3Connection, secret: "sk"))
        XCTAssertNotNil(p.s3)
        XCTAssertEqual(p.currentPath, "/")
    }

    func testLeaveRemovedSessionsFallsBackToLocal() {
        let p = PanelState(path: "/Users/me")
        p.connectSFTP(sftpConn, initialPath: "/home/ubuntu")

        // Session still present: no-op.
        p.leaveRemovedSessions(existingIDs: [RemoteSession.sftp(sftpConn).id])
        XCTAssertNotNil(p.sftp)

        // Session ejected (possibly from the other panel): back to local.
        p.leaveRemovedSessions(existingIDs: [])
        XCTAssertNil(p.sftp)
        XCTAssertFalse(p.isRemote)
    }

    func testConnectS3WhileOnSFTPClearsSFTPSession() {
        let p = PanelState(path: "/Users/me")
        p.connectSFTP(sftpConn, initialPath: "/home/ubuntu")
        XCTAssertNotNil(p.sftp)

        p.connectS3(s3Connection, secret: "sk", initialPath: "/b")

        XCTAssertNil(p.sftp, "connecting S3 must drop the previous SFTP session")
        XCTAssertNotNil(p.s3)
        XCTAssertTrue(p.fs is S3FS)
        XCTAssertEqual(p.currentPath, "/b")
    }
}
