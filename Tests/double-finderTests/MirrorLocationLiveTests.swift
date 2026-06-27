import XCTest
@testable import double_finder

/// Live SFTP end-to-end test for `PanelState.mirrorLocation` — the "Open in other
/// panel" / "Same folder in other panel" fix. Verifies that when the source panel
/// is on a real SFTP session, the OTHER panel actually joins that session and
/// loads the REMOTE directory listing (not a local path). Skipped unless
/// `SFTP_LIVE=1`. Run with:
///   SFTP_LIVE=1 swift test --filter MirrorLocationLiveTests
///
/// Assumes the test server (see CLAUDE.md §7) is reachable and that
/// `/home/ubuntu/df_test_sub` exists with `file_a.txt` and `inner/`.
@MainActor
final class MirrorLocationLiveTests: XCTestCase {

    private let conn = SFTPConnection(
        host: "10.17.20.55", user: "ubuntu", port: 22,
        keyPath: "~/.ssh/id_rsa", remotePath: "/home/ubuntu", name: "df-test")

    /// Polls a panel's items (loaded asynchronously) until non-empty or timeout.
    private func waitForItems(_ panel: PanelState, timeout: TimeInterval = 20) async throws {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while panel.items.filter({ $0.name != ".." }).isEmpty {
            if Date() > deadline { XCTFail("timed out loading \(panel.currentPath)"); return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func testOpenInOtherPanelJoinsSFTPSession() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SFTP_LIVE"] == "1", "set SFTP_LIVE=1 to run the live SFTP test")

        // --- Source panel connects to the real SFTP server ---
        let source = PanelState(path: "/home/ubuntu")
        source.connectSFTP(conn, initialPath: "/home/ubuntu")
        try await waitForItems(source)
        XCTAssertNotNil(source.sftp, "source must be on SFTP")
        XCTAssertTrue(source.items.contains { $0.name == "df_test_sub" },
                      "source /home/ubuntu should list df_test_sub")

        // --- Other panel starts LOCAL, then mirrors a remote subdir ---
        let other = PanelState(path: "/Users/\(NSUserName())")
        XCTAssertFalse(other.isRemote)

        let target = "/home/ubuntu/df_test_sub"
        other.mirrorLocation(of: source, path: target)

        // The bug: previously `other` stayed local and listed the path against the
        // local FS (empty / wrong). The fix makes it join the SFTP session.
        XCTAssertEqual(other.sftp, conn, "other panel must join the SFTP session")
        XCTAssertEqual(other.currentPath, target)
        XCTAssertTrue(other.isRemote)

        try await waitForItems(other)
        let names = Set(other.items.map { $0.name })
        XCTAssertTrue(names.contains("file_a.txt"),
                      "other panel must load the REMOTE listing of df_test_sub; got \(names)")
        XCTAssertTrue(names.contains("inner"),
                      "other panel must show the remote subfolder; got \(names)")
    }
}
