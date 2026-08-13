import XCTest
@testable import double_finder

/// MTP is an object tree, not a filesystem: the same folder can legitimately
/// hold several objects with identical names. Uploading without clearing them
/// first leaves duplicates on the phone and makes any later name-based operation
/// ambiguous, so every upload deletes same-named objects up front.
final class MTPNameConflictTests: XCTestCase {
    private func children(_ pairs: [(String, UInt32)],
                          dirs: Set<String> = []) -> [(name: String, id: UInt32, isDir: Bool)] {
        pairs.map { (name: $0.0, id: $0.1, isDir: dirs.contains($0.0)) }
    }

    func testReturnsIDsOfSameNamedObjects() {
        let ids = MTPConflict.objectsToReplace(named: "a.txt",
                                               in: children([("a.txt", 7), ("b.txt", 8)]))
        XCTAssertEqual(ids, [7])
    }

    /// A device that already accumulated duplicates (another tool wrote them)
    /// gets fully cleaned, not just the first hit.
    func testReturnsAllDuplicates() {
        let ids = MTPConflict.objectsToReplace(named: "a.txt",
                                               in: children([("a.txt", 7), ("a.txt", 9)]))
        XCTAssertEqual(ids, [7, 9])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(MTPConflict.objectsToReplace(named: "c.txt",
                                                   in: children([("a.txt", 7)])).isEmpty)
    }

    /// Android storage is case-sensitive (ext4/f2fs), so "A.txt" and "a.txt" are
    /// two distinct objects and must not clobber each other.
    func testCaseSensitive() {
        XCTAssertTrue(MTPConflict.objectsToReplace(named: "A.txt",
                                                   in: children([("a.txt", 7)])).isEmpty)
    }

    /// Uploading a file must not delete a *folder* that happens to share the name —
    /// that would silently destroy a whole subtree.
    func testFoldersAreNeverReplaced() {
        let ids = MTPConflict.objectsToReplace(named: "Download",
                                               in: children([("Download", 5)], dirs: ["Download"]))
        XCTAssertTrue(ids.isEmpty)
    }

    func testChineseAndSpacedNamesMatchExactly() {
        let listing = children([(" 我的文件", 1), ("我的文件", 2)])
        XCTAssertEqual(MTPConflict.objectsToReplace(named: " 我的文件", in: listing), [1])
        XCTAssertEqual(MTPConflict.objectsToReplace(named: "我的文件", in: listing), [2])
    }
}
