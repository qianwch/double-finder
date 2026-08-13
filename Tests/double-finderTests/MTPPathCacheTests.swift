import XCTest
@testable import double_finder

/// Pure-logic tests for path→object-id caching and lazy resolution.
/// The listing step (the only part that touches USB) is injected, so the whole
/// walk-down algorithm is testable without a phone.
final class MTPPathCacheTests: XCTestCase {
    /// Stands in for `LIBMTP_Get_Files_And_Folders`, keyed by "storage:object",
    /// and counts how many directory listings the resolver actually performed.
    private final class FakeLister {
        private let tree: [String: [(name: String, id: UInt32, isDir: Bool)]]
        private(set) var calls = 0

        init(_ tree: [String: [(name: String, id: UInt32, isDir: Bool)]]) { self.tree = tree }

        func list(_ node: MTPNode, _ path: String) -> [(name: String, id: UInt32, isDir: Bool)] {
            calls += 1
            return tree["\(node.storageID):\(node.objectID)"] ?? []
        }

        func resetCount() { calls = 0 }
    }

    private let storageRoot = MTPNode(storageID: 1, objectID: MTPNode.rootObjectID)

    func testCachesListedChildren() {
        let cache = MTPPathCache()
        cache.record(path: "/Internal storage", node: storageRoot)
        cache.record(path: "/Internal storage/DCIM", node: MTPNode(storageID: 1, objectID: 10))

        XCTAssertEqual(cache.cached("/Internal storage/DCIM"), MTPNode(storageID: 1, objectID: 10))
        XCTAssertNil(cache.cached("/Internal storage/Missing"))
    }

    func testResolveWalksDownFromStorageRootOnMiss() async throws {
        let cache = MTPPathCache()
        cache.record(path: "/Internal storage", node: storageRoot)
        let lister = FakeLister([
            "1:\(MTPNode.rootObjectID)": [(name: "DCIM", id: 10, isDir: true)],
            "1:10": [(name: "Camera", id: 20, isDir: true)],
            "1:20": [(name: "IMG.jpg", id: 30, isDir: false)],
        ])

        let node = try await cache.resolve("/Internal storage/DCIM/Camera/IMG.jpg",
                                           listing: { lister.list($0, $1) })
        XCTAssertEqual(node, MTPNode(storageID: 1, objectID: 30))
        XCTAssertEqual(lister.calls, 3, "one listing per level")

        // Second time everything is cached — no USB traffic at all.
        lister.resetCount()
        let again = try await cache.resolve("/Internal storage/DCIM/Camera/IMG.jpg",
                                            listing: { lister.list($0, $1) })
        XCTAssertEqual(again, MTPNode(storageID: 1, objectID: 30))
        XCTAssertEqual(lister.calls, 0)
    }

    /// Siblings seen while walking are cached too, so the next lookup is free.
    func testSiblingsAreCachedDuringWalk() async throws {
        let cache = MTPPathCache()
        cache.record(path: "/S", node: storageRoot)
        let lister = FakeLister([
            "1:\(MTPNode.rootObjectID)": [(name: "a", id: 1, isDir: true),
                                          (name: "b", id: 2, isDir: true)],
        ])

        _ = try await cache.resolve("/S/a", listing: { lister.list($0, $1) })
        XCTAssertEqual(cache.cached("/S/b"), MTPNode(storageID: 1, objectID: 2))
    }

    func testResolveThrowsOnMissingComponent() async {
        let cache = MTPPathCache()
        cache.record(path: "/Internal storage", node: storageRoot)
        let lister = FakeLister([
            "1:\(MTPNode.rootObjectID)": [(name: "DCIM", id: 10, isDir: true)],
        ])

        do {
            _ = try await cache.resolve("/Internal storage/Nope", listing: { lister.list($0, $1) })
            XCTFail("expected MTPNotFoundError")
        } catch {
            XCTAssertTrue(error is MTPNotFoundError, "got \(type(of: error))")
        }
    }

    /// An unknown storage can't be walked into — there's no root to start from.
    func testResolveThrowsWhenStorageUnknown() async {
        let cache = MTPPathCache()
        let lister = FakeLister([:])
        do {
            _ = try await cache.resolve("/Nonexistent/x", listing: { lister.list($0, $1) })
            XCTFail("expected MTPNotFoundError")
        } catch {
            XCTAssertTrue(error is MTPNotFoundError)
        }
    }

    /// After delete/rename/move the stale ids must go, or they'd address objects
    /// that no longer exist.
    func testInvalidateDropsSubtree() {
        let cache = MTPPathCache()
        cache.record(path: "/S/a", node: MTPNode(storageID: 1, objectID: 1))
        cache.record(path: "/S/a/b", node: MTPNode(storageID: 1, objectID: 2))
        cache.record(path: "/S/a/b/c", node: MTPNode(storageID: 1, objectID: 3))
        cache.record(path: "/S/ab", node: MTPNode(storageID: 1, objectID: 4))

        cache.invalidate("/S/a")

        XCTAssertNil(cache.cached("/S/a"))
        XCTAssertNil(cache.cached("/S/a/b"))
        XCTAssertNil(cache.cached("/S/a/b/c"))
        XCTAssertNotNil(cache.cached("/S/ab"), "shared prefix but not a subpath — must survive")
    }

    /// Real device paths: Chinese storage name plus a leading-space folder.
    func testResolveWithChineseAndSpacedNames() async throws {
        let cache = MTPPathCache()
        cache.record(path: "/内部存储", node: storageRoot)
        let lister = FakeLister([
            "1:\(MTPNode.rootObjectID)": [(name: " 我的文件", id: 42, isDir: true)],
            "1:42": [(name: "note.txt", id: 43, isDir: false)],
        ])

        let node = try await cache.resolve("/内部存储/ 我的文件/note.txt",
                                           listing: { lister.list($0, $1) })
        XCTAssertEqual(node, MTPNode(storageID: 1, objectID: 43))
    }
}
