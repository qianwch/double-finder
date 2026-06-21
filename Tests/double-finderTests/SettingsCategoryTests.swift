import XCTest
@testable import double_finder
@MainActor
final class SettingsCategoryTests: XCTestCase {
    func testRegistryHasSevenCategoriesInOrder() {
        let c = SettingsWindowController(installedTerminals: ["Terminal"])
        XCTAssertEqual(c.categoryIDs, ["general","display","panels","operation","toolbar","shortcuts","favorites"])
    }
    func testCategoryIndexResolves() {
        let c = SettingsWindowController(installedTerminals: ["Terminal"])
        XCTAssertEqual(c.categoryIndex(for: "favorites"), 6)
        XCTAssertEqual(c.categoryIndex(for: "general"), 0)
        XCTAssertNil(c.categoryIndex(for: "nope"))
    }
    func testIDsAreUnique() {
        let c = SettingsWindowController(installedTerminals: ["Terminal"])
        XCTAssertEqual(Set(c.categoryIDs).count, c.categoryIDs.count)
    }
}
