import XCTest
@testable import double_finder

final class PrivilegedRunnerTests: XCTestCase {
    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(PrivilegedRunner.shellQuote("a b"), "'a b'")
        XCTAssertEqual(PrivilegedRunner.shellQuote("it's"), "'it'\\''s'")
    }

    func testAppleScriptQuoteEscapesBackslashAndQuote() {
        XCTAssertEqual(PrivilegedRunner.appleScriptQuote(#"say "hi" \ bye"#), #"say \"hi\" \\ bye"#)
    }

    func testCommandsPerOperationType() {
        XCTAssertEqual(PrivilegedRunner.command(for: .delete, paths: ["/Applications/X.app", "/tmp/y"], destination: nil),
                       "rm -rf '/Applications/X.app' && rm -rf '/tmp/y'")
        XCTAssertEqual(PrivilegedRunner.command(for: .copy, paths: ["/a/f"], destination: "/Applications"),
                       "cp -pR '/a/f' '/Applications'/")
        XCTAssertEqual(PrivilegedRunner.command(for: .move, paths: ["/a/f"], destination: "/d"),
                       "mv -f '/a/f' '/d'/")
        XCTAssertEqual(PrivilegedRunner.command(for: .copy, paths: ["/a/f"], destination: nil), "")
    }

    func testPermissionDeniedDetection() {
        XCTAssertTrue(PrivilegedRunner.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertTrue(PrivilegedRunner.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertTrue(PrivilegedRunner.isPermissionDenied(NSError(domain: "x", code: 1,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        XCTAssertFalse(PrivilegedRunner.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }
}
