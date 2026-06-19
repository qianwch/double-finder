import XCTest
@testable import double_finder

final class SMBAuthTests: XCTestCase {

    /// `smbutil view` output → mountable disk share names (skip header/separator,
    /// non-disk types, and hidden `$` admin shares).
    func testParseShareNames() {
        let output = """
        Share                                           Type    Comments
        -------------------------------
        home                                            disk
        homes                                           disk
        TimeMachine                                     disk    Backups
        Public                                          disk
        IPC$                                            pipe    Remote IPC
        ADMIN$                                          disk
        HP_Printer                                      printer
        4 shares listed from 4 available
        """
        XCTAssertEqual(SMBMounter.parseShareNames(from: output),
                       ["home", "homes", "TimeMachine", "Public"])
    }

    func testParseShareNamesEmpty() {
        XCTAssertEqual(SMBMounter.parseShareNames(from: ""), [])
    }

    func testClassifySuccess() {
        XCTAssertNil(SMBMountError.classify(0))
    }

    func testClassifyAuthFailure() {
        XCTAssertEqual(SMBMountError.classify(80), .authFailed)   // EAUTH
        XCTAssertEqual(SMBMountError.classify(13), .authFailed)   // EACCES
    }

    /// Guest/account/auth-mechanism NetFS codes mean "you need (real) credentials"
    /// — they must re-prompt, not dead-end as a generic failure.
    func testClassifyNeedsCredentials() {
        XCTAssertEqual(SMBMountError.classify(-6004), .needsCredentials)  // guest not supported
        XCTAssertEqual(SMBMountError.classify(-5997), .needsCredentials)  // no auth mech
        XCTAssertEqual(SMBMountError.classify(-5999), .needsCredentials)  // account restricted (guest)
        XCTAssertEqual(SMBMountError.classify(-5045), .needsCredentials)  // pwd needs change
        XCTAssertEqual(SMBMountError.classify(-5046), .needsCredentials)  // pwd policy
    }

    func testClassifyOther() {
        XCTAssertEqual(SMBMountError.classify(2), .other(2))         // ENOENT-ish
        XCTAssertEqual(SMBMountError.classify(64), .other(64))       // EHOSTDOWN-ish
        XCTAssertEqual(SMBMountError.classify(-6003), .other(-6003)) // no shares available
        XCTAssertEqual(SMBMountError.classify(-6602), .other(-6602)) // mount failed
    }

    /// The auth-ish errors must report as "should re-prompt".
    func testIsAuthIssue() {
        XCTAssertTrue(SMBMountError.authFailed.isAuthIssue)
        XCTAssertTrue(SMBMountError.needsCredentials.isAuthIssue)
        XCTAssertFalse(SMBMountError.other(2).isAuthIssue)
    }

    func testQueryIncludesServerAndProtocolNoAccount() {
        let q = SMBCredentialStore.query(host: "nas.local", account: nil)
        XCTAssertEqual(q[kSecAttrServer as String] as? String, "nas.local")
        XCTAssertNotNil(q[kSecAttrProtocol as String])
        XCTAssertNil(q[kSecAttrAccount as String])
        XCTAssertNotNil(q[kSecClass as String])
    }

    func testQueryIncludesAccountWhenGiven() {
        let q = SMBCredentialStore.query(host: "nas.local", account: "bob")
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "bob")
        XCTAssertEqual(q[kSecAttrServer as String] as? String, "nas.local")
    }
}
