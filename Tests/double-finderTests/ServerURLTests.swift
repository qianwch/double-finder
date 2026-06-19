import XCTest
@testable import double_finder

final class ServerURLTests: XCTestCase {

    func testSMBBasic() {
        let u = ServerURL("smb://nas/share")
        XCTAssertEqual(u?.scheme, .smb)
        XCTAssertEqual(u?.host, "nas")
        XCTAssertNil(u?.port)
        XCTAssertNil(u?.user)
        XCTAssertEqual(u?.share, "share")
    }

    func testSMBWithUserPortShare() {
        let u = ServerURL("smb://alice@nas.local:445/Media")
        XCTAssertEqual(u?.scheme, .smb)
        XCTAssertEqual(u?.host, "nas.local")
        XCTAssertEqual(u?.port, 445)
        XCTAssertEqual(u?.user, "alice")
        XCTAssertEqual(u?.share, "Media")
    }

    func testSMBHostOnly() {
        let u = ServerURL("smb://nas")
        XCTAssertEqual(u?.scheme, .smb)
        XCTAssertEqual(u?.host, "nas")
        XCTAssertNil(u?.share)
    }

    func testSFTP() {
        let u = ServerURL("sftp://bob@host:2222/home/bob")
        XCTAssertEqual(u?.scheme, .sftp)
        XCTAssertEqual(u?.host, "host")
        XCTAssertEqual(u?.port, 2222)
        XCTAssertEqual(u?.user, "bob")
        XCTAssertEqual(u?.share, "home/bob")
    }

    func testRejectsUnsupportedAndGarbage() {
        XCTAssertNil(ServerURL("http://example.com"))
        XCTAssertNil(ServerURL("not a url"))
        XCTAssertNil(ServerURL("smb://"))   // no host
        XCTAssertNil(ServerURL(""))
    }

    func testNewMountPathsReturnsOnlyFreshVolumes() {
        let before: Set<String> = ["/", "/Volumes/Macintosh HD"]
        let after: Set<String> = ["/", "/Volumes/Macintosh HD", "/Volumes/Media", "/System/x"]
        XCTAssertEqual(newMountPaths(before: before, after: after), ["/Volumes/Media"])
    }

    func testNewMountPathsEmptyWhenNothingNew() {
        let s: Set<String> = ["/", "/Volumes/A"]
        XCTAssertEqual(newMountPaths(before: s, after: s), [])
    }
}
