import XCTest
@testable import double_finder

final class SMBAuthTests: XCTestCase {

    func testClassifySuccess() {
        XCTAssertNil(SMBMountError.classify(0))
    }

    func testClassifyAuthFailure() {
        XCTAssertEqual(SMBMountError.classify(80), .authFailed)   // EAUTH
        XCTAssertEqual(SMBMountError.classify(13), .authFailed)   // EACCES
    }

    func testClassifyOther() {
        XCTAssertEqual(SMBMountError.classify(2), .other(2))      // ENOENT-ish
        XCTAssertEqual(SMBMountError.classify(64), .other(64))    // EHOSTDOWN-ish
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
