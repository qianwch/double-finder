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
}
