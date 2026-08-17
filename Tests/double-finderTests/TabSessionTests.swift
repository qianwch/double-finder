import XCTest
@testable import double_finder

final class TabSessionTests: XCTestCase {

    func testEncodeDecodeRoundtrip() {
        let tabs = [TabSession.Tab(path: "/a", locked: false),
                    TabSession.Tab(path: "/b/c", locked: true),
                    TabSession.Tab(path: "/d", locked: true, lockedPath: "/d/e")]
        let decoded = TabSession.decode(TabSession.encode(tabs),
                                        isDirectory: { _ in true }, fallback: "/home")
        XCTAssertEqual(decoded, tabs)
    }

    func testDecodeUnreachablePathFallsBackToHome() {
        let raw = TabSession.encode([TabSession.Tab(path: "/gone", locked: true)])
        let decoded = TabSession.decode(raw, isDirectory: { _ in false }, fallback: "/home")
        XCTAssertEqual(decoded, [TabSession.Tab(path: "/home", locked: true)])
    }

    func testDecodeGoneLockedFolderDropsMemoryNotLock() {
        // The captured folder vanished between runs: the tab degrades to a
        // plain lock instead of snapping into a dead path.
        let raw = TabSession.encode([TabSession.Tab(path: "/a", locked: true, lockedPath: "/gone")])
        let decoded = TabSession.decode(raw, isDirectory: { $0 != "/gone" }, fallback: "/home")
        XCTAssertEqual(decoded, [TabSession.Tab(path: "/a", locked: true, lockedPath: nil)])
    }

    func testDecodeIgnoresLockedPathOnUnlockedTab() {
        let raw: [[String: String]] = [["path": "/a", "locked": "0", "lockedPath": "/b"]]
        let decoded = TabSession.decode(raw, isDirectory: { _ in true }, fallback: "/home")
        XCTAssertEqual(decoded, [TabSession.Tab(path: "/a", locked: false, lockedPath: nil)])
    }

    func testEncodeOmitsLockedPathWhenNil() {
        let raw = TabSession.encode([TabSession.Tab(path: "/a", locked: true)])
        XCTAssertNil(raw[0]["lockedPath"])
    }

    func testDecodeGarbageReturnsEmpty() {
        XCTAssertEqual(TabSession.decode(nil, isDirectory: { _ in true }, fallback: "/h"), [])
        XCTAssertEqual(TabSession.decode("junk", isDirectory: { _ in true }, fallback: "/h"), [])
        XCTAssertEqual(TabSession.decode([42], isDirectory: { _ in true }, fallback: "/h"), [])
    }

    func testDecodeDropsEntriesWithoutPath() {
        let raw: [[String: String]] = [["locked": "1"], ["path": "", "locked": "0"],
                                       ["path": "/ok", "locked": "0"]]
        let decoded = TabSession.decode(raw, isDirectory: { _ in true }, fallback: "/h")
        XCTAssertEqual(decoded, [TabSession.Tab(path: "/ok", locked: false)])
    }

    func testClampActive() {
        XCTAssertEqual(TabSession.clampActive(2, count: 3), 2)
        XCTAssertEqual(TabSession.clampActive(5, count: 3), 2)
        XCTAssertEqual(TabSession.clampActive(-1, count: 3), 0)
        XCTAssertEqual(TabSession.clampActive(0, count: 0), 0)
    }
}
