import XCTest
@testable import double_finder

/// Live SFTP end-to-end test for server-side copy/move within one host
/// (`SFTPFS.serverTransfer`). Proves bytes are transferred entirely on the remote
/// (remote `cp`/`mv`) — a file copied/moved between two remote dirs, plus a folder
/// copied recursively. Skipped unless `SFTP_LIVE=1`. Run with:
///   SFTP_LIVE=1 swift test --filter SFTPSameHostLiveTests
final class SFTPSameHostLiveTests: XCTestCase {

    private let fs = SFTPFS(connection: SFTPConnection(
        host: "10.17.20.55", user: "ubuntu", port: 22,
        keyPath: "~/.ssh/id_rsa", remotePath: "/home/ubuntu", name: "df-test"))

    private func remoteNames(_ dir: String) async throws -> Set<String> {
        Set(try await fs.listDirectory(dir).map { $0.name })
    }

    func testServerSideCopyAndMove() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SFTP_LIVE"] == "1", "set SFTP_LIVE=1 to run the live SFTP test")

        let root = "/home/ubuntu/df_samehost_\(ProcessInfo.processInfo.globallyUniqueString)"
        // Build a fixture: src/ (file.txt + sub/inner.txt), and empty dstCopy/ dstMove/.
        _ = try await fs.runCommand(
            "mkdir -p \(SFTPFS.shellQuote(root))/src/sub " +
            "\(SFTPFS.shellQuote(root))/dstCopy \(SFTPFS.shellQuote(root))/dstMove && " +
            "echo hello > \(SFTPFS.shellQuote(root))/src/file.txt && " +
            "echo deep > \(SFTPFS.shellQuote(root))/src/sub/inner.txt")
        defer {
            Task { _ = try? await fs.runCommand("rm -rf \(SFTPFS.shellQuote(root))") }
        }

        // --- Server-side COPY of a file: appears in dest, still present in source ---
        try await fs.serverTransfer(from: "\(root)/src/file.txt", toDir: "\(root)/dstCopy", move: false)
        var copyDst = try await remoteNames("\(root)/dstCopy")
        XCTAssertTrue(copyDst.contains("file.txt"), "copied file should appear in dstCopy; got \(copyDst)")
        let srcAfterCopy = try await remoteNames("\(root)/src")
        XCTAssertTrue(srcAfterCopy.contains("file.txt"), "copy must leave the source file in place")

        // --- Server-side COPY of a folder: recurses, preserving the tree ---
        try await fs.serverTransfer(from: "\(root)/src/sub", toDir: "\(root)/dstCopy", move: false)
        copyDst = try await remoteNames("\(root)/dstCopy")
        XCTAssertTrue(copyDst.contains("sub"), "copied folder should appear in dstCopy; got \(copyDst)")
        let subDst = try await remoteNames("\(root)/dstCopy/sub")
        XCTAssertTrue(subDst.contains("inner.txt"), "folder copy must recurse; got \(subDst)")

        // --- Server-side MOVE of a file: appears in dest, GONE from source ---
        try await fs.serverTransfer(from: "\(root)/src/file.txt", toDir: "\(root)/dstMove", move: true)
        let moveDst = try await remoteNames("\(root)/dstMove")
        XCTAssertTrue(moveDst.contains("file.txt"), "moved file should appear in dstMove; got \(moveDst)")
        let srcAfterMove = try await remoteNames("\(root)/src")
        XCTAssertFalse(srcAfterMove.contains("file.txt"), "move must delete the source file; got \(srcAfterMove)")
    }
}
