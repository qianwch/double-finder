import XCTest
@testable import double_finder

/// Pure-logic tests for the same-SFTP-host server-side copy/move feature:
/// `SFTPConnection.sameHost`, `SFTPFS.shellQuote`, and the remote command builder.
final class SFTPSameHostTests: XCTestCase {

    private func conn(host: String = "h", user: String = "u", port: Int = 22,
                      path: String = "~", name: String = "") -> SFTPConnection {
        SFTPConnection(host: host, user: user, port: port, keyPath: "~/.ssh/id_rsa",
                       remotePath: path, name: name)
    }

    // MARK: - sameHost

    func testSameHostIgnoresPathNameAndKey() {
        let a = conn(path: "/home/ubuntu", name: "A")
        let b = conn(path: "/var/data", name: "B")
        XCTAssertTrue(a.sameHost(as: b), "same host+user+port should match regardless of path/name")
    }

    func testSameHostFalseOnDifferentHostUserOrPort() {
        let base = conn()
        XCTAssertFalse(base.sameHost(as: conn(host: "other")))
        XCTAssertFalse(base.sameHost(as: conn(user: "root")))
        XCTAssertFalse(base.sameHost(as: conn(port: 2222)))
    }

    // MARK: - shellQuote

    func testShellQuoteWrapsAndEscapes() {
        XCTAssertEqual(SFTPFS.shellQuote("/home/ubuntu/a"), "'/home/ubuntu/a'")
        XCTAssertEqual(SFTPFS.shellQuote("a b/c"), "'a b/c'")
        // Embedded single quote → close, escaped quote, reopen.
        XCTAssertEqual(SFTPFS.shellQuote("it's"), "'it'\\''s'")
        // Shell metacharacters stay inside the single quotes (inert).
        XCTAssertEqual(SFTPFS.shellQuote("$x;`y`"), "'$x;`y`'")
    }

    // MARK: - serverTransferCommand

    func testServerCopyCommand() {
        let cmd = SFTPFS.serverTransferCommand(from: "/home/ubuntu/file a.txt",
                                               toDir: "/home/ubuntu/dst", move: false)
        XCTAssertEqual(cmd, "cp -af -- '/home/ubuntu/file a.txt' '/home/ubuntu/dst/'")
    }

    func testServerMoveCommandKeepsExistingTrailingSlash() {
        let cmd = SFTPFS.serverTransferCommand(from: "/a/b", toDir: "/c/d/", move: true)
        XCTAssertEqual(cmd, "mv -f -- '/a/b' '/c/d/'")
    }

    func testServerCommandIsInjectionSafe() {
        // A malicious name must not break out of the quoted word.
        let cmd = SFTPFS.serverTransferCommand(from: "/a/$(rm -rf ~)", toDir: "/d", move: false)
        XCTAssertEqual(cmd, "cp -af -- '/a/$(rm -rf ~)' '/d/'")
    }
}
