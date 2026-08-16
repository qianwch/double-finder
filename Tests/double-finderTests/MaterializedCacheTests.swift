import XCTest
@testable import double_finder

/// F3 materializes remote / inside-archive items into a temp file before showing
/// them. Re-viewing the same file (⌘↑ / ⌘↓ back and forth) must reuse that file
/// instead of paying the download / decompression again — on a solid 7z a single
/// entry costs a full pass over the archive.
final class MaterializedCacheTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testSlugIsStableForTheSameItem() {
        let a = MaterializedCache.slug(path: "/arc.7z/dir/f.txt", size: 850, modified: epoch)
        let b = MaterializedCache.slug(path: "/arc.7z/dir/f.txt", size: 850, modified: epoch)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    /// Any change to identity, size or mtime must land in a DIFFERENT folder, so a
    /// changed remote file can never be served from a stale cached copy.
    func testSlugChangesWithPathSizeOrDate() {
        let base = MaterializedCache.slug(path: "/arc.7z/f.txt", size: 850, modified: epoch)
        XCTAssertNotEqual(base, MaterializedCache.slug(path: "/arc.7z/g.txt", size: 850, modified: epoch))
        XCTAssertNotEqual(base, MaterializedCache.slug(path: "/arc.7z/f.txt", size: 851, modified: epoch))
        XCTAssertNotEqual(base, MaterializedCache.slug(path: "/arc.7z/f.txt", size: 850,
                                                       modified: epoch.addingTimeInterval(1)))
    }

    func testFreshOnlyWhenFileExistsWithTheExpectedSize() throws {
        let fm = FileManager.default
        let dir = NSTemporaryDirectory() + "matcache-\(ProcessInfo.processInfo.globallyUniqueString)"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: dir) }
        let path = dir + "/f.txt"

        XCTAssertFalse(MaterializedCache.isFresh(localPath: path, expectedSize: 3), "missing file is not a hit")

        try Data("abc".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(MaterializedCache.isFresh(localPath: path, expectedSize: 3))
        // A half-written file (interrupted extract) must not be served as a hit.
        XCTAssertFalse(MaterializedCache.isFresh(localPath: path, expectedSize: 4))
    }
}
