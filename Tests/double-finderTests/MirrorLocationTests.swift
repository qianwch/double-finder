import XCTest
@testable import double_finder

/// Tests for `PanelState.mirrorLocation(of:path:)` — the state transition behind
/// "Open in other panel" / "Match other panel" when the source panel is on a
/// remote backend (SFTP/S3). The other panel must JOIN the same remote session
/// rather than list the remote path against the local filesystem.
@MainActor
final class MirrorLocationTests: XCTestCase {

    private let sftpConn = SFTPConnection(host: "h", user: "u")
    private func s3Conn(_ bucket: String = "") -> S3Connection {
        S3Connection(name: "n", endpoint: "https://s3.example.com",
                     region: "us-east-1", bucket: bucket, accessKey: "AK", pathStyle: true)
    }

    // MARK: - SFTP source

    func testMirrorFromSFTPJoinsRemoteSession() {
        let source = PanelState(path: "/home/ubuntu")
        source.sftp = sftpConn

        let target = PanelState(path: "/Users/me")    // local
        XCTAssertFalse(target.isRemote)

        target.mirrorLocation(of: source, path: "/home/ubuntu/docs")

        XCTAssertEqual(target.sftp, sftpConn, "target should join source's SFTP connection")
        XCTAssertEqual(target.currentPath, "/home/ubuntu/docs")
        XCTAssertTrue(target.isRemote)
    }

    func testMirrorWhenAlreadySameSFTPJustNavigates() {
        let source = PanelState(path: "/home/ubuntu")
        source.sftp = sftpConn

        let target = PanelState(path: "/home/ubuntu")
        target.sftp = sftpConn
        let historyBefore = target.history.count

        target.mirrorLocation(of: source, path: "/home/ubuntu/sub")

        XCTAssertEqual(target.sftp, sftpConn)
        XCTAssertEqual(target.currentPath, "/home/ubuntu/sub")
        // navigate() (not a reconnect) appends to history rather than resetting it.
        XCTAssertEqual(target.history.count, historyBefore + 1,
                       "same-session mirror should navigate (append history), not reconnect (reset)")
    }

    // MARK: - S3 source

    func testMirrorFromS3JoinsRemoteSession() {
        let source = PanelState(path: "/bucket/dir")
        source.s3 = s3Conn()

        let target = PanelState(path: "/Users/me")
        target.mirrorLocation(of: source, path: "/bucket/dir/sub")

        XCTAssertEqual(target.s3, s3Conn(), "target should join source's S3 connection")
        XCTAssertEqual(target.currentPath, "/bucket/dir/sub")
        XCTAssertTrue(target.isRemote)
    }

    // MARK: - Local source leaves any remote session the target holds

    func testMirrorFromLocalLeavesTargetSFTP() {
        let source = PanelState(path: "/Users/me/Documents")   // local

        let target = PanelState(path: "/home/ubuntu")
        target.sftp = sftpConn                                  // target was remote
        XCTAssertTrue(target.isRemote)

        target.mirrorLocation(of: source, path: "/Users/me/Documents")

        XCTAssertNil(target.sftp, "mirroring a local source must drop the target's SFTP session")
        XCTAssertFalse(target.isRemote)
        XCTAssertEqual(target.currentPath, "/Users/me/Documents")
    }

    func testMirrorFromLocalLeavesTargetS3() {
        let source = PanelState(path: "/Users/me/Documents")

        let target = PanelState(path: "/bucket")
        target.s3 = s3Conn()
        XCTAssertTrue(target.isRemote)

        target.mirrorLocation(of: source, path: "/Users/me/Documents")

        XCTAssertNil(target.s3, "mirroring a local source must drop the target's S3 session")
        XCTAssertFalse(target.isRemote)
    }
}
