import XCTest
@testable import double_finder

/// FavoriteItem model + legacy migration + menu grouping. Uses the real
/// UserDefaults keys, so each test snapshots and restores them.
final class FavoritesTests: XCTestCase {
    private var savedItems: Any?
    private var savedLegacy: Any?

    override func setUp() {
        let d = UserDefaults.standard
        savedItems = d.object(forKey: "FavoriteItems")
        savedLegacy = d.object(forKey: "Favorites")
        d.removeObject(forKey: "FavoriteItems")
        d.removeObject(forKey: "Favorites")
    }

    override func tearDown() {
        let d = UserDefaults.standard
        if let v = savedItems { d.set(v, forKey: "FavoriteItems") } else { d.removeObject(forKey: "FavoriteItems") }
        if let v = savedLegacy { d.set(v, forKey: "Favorites") } else { d.removeObject(forKey: "Favorites") }
    }

    func testDisplayNameFallsBackToLeaf() {
        XCTAssertEqual(FavoriteItem(path: "/tmp/Projects").displayName, "Projects")
        XCTAssertEqual(FavoriteItem(path: "/tmp/Projects", name: "Work").displayName, "Work")
        XCTAssertEqual(FavoriteItem(path: "/").displayName, "/")
    }

    func testLegacyMigration() {
        UserDefaults.standard.set(["/a", "/b/c"], forKey: "Favorites")
        let items = Favorites.items()
        XCTAssertEqual(items.map(\.path), ["/a", "/b/c"])
        XCTAssertTrue(items.allSatisfy { $0.name.isEmpty && $0.group.isEmpty })
        // Legacy key consumed; new key written.
        XCTAssertNil(UserDefaults.standard.object(forKey: "Favorites"))
        XCTAssertNotNil(UserDefaults.standard.object(forKey: "FavoriteItems"))
        // Second read comes from the new store.
        XCTAssertEqual(Favorites.all(), ["/a", "/b/c"])
    }

    func testRoundTripPreservesNameAndGroup() {
        Favorites.setItems([FavoriteItem(path: "/x", name: "X!", group: "Dev"),
                            FavoriteItem(path: "/y")])
        let items = Favorites.items()
        XCTAssertEqual(items, [FavoriteItem(path: "/x", name: "X!", group: "Dev"),
                               FavoriteItem(path: "/y")])
    }

    func testAddRemoveContains() {
        Favorites.add("/one")
        Favorites.add("/one")            // no duplicate
        Favorites.add("/two")
        XCTAssertEqual(Favorites.all(), ["/one", "/two"])
        XCTAssertTrue(Favorites.contains("/one"))
        Favorites.remove("/one")
        XCTAssertEqual(Favorites.all(), ["/two"])
    }

    func testGroupedOrdering() {
        Favorites.setItems([
            FavoriteItem(path: "/top1"),
            FavoriteItem(path: "/dev1", group: "Dev"),
            FavoriteItem(path: "/top2"),
            FavoriteItem(path: "/doc1", group: "Docs"),
            FavoriteItem(path: "/dev2", group: "Dev"),
        ])
        let (top, groups) = Favorites.grouped()
        XCTAssertEqual(top.map(\.path), ["/top1", "/top2"])
        XCTAssertEqual(groups.map(\.name), ["Dev", "Docs"])   // first-appearance order
        XCTAssertEqual(groups[0].items.map(\.path), ["/dev1", "/dev2"])
        XCTAssertEqual(groups[1].items.map(\.path), ["/doc1"])
    }
}
