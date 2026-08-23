import XCTest
@testable import double_finder

/// The "Reset to Defaults" key tables. These run against a private
/// UserDefaults suite, never the app's own domain, so a failing test can't
/// wipe the developer's settings.
final class SettingsResetTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "net.qian.double-finder.tests.reset"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Table shape

    func testEveryResettableCategoryOwnsSomething() {
        for id in SettingsReset.resettableCategories {
            let keys = SettingsReset.keysByCategory[id] ?? []
            let prefixes = SettingsReset.prefixesByCategory[id] ?? []
            XCTAssertFalse(keys.isEmpty && prefixes.isEmpty,
                           "category \(id) resets nothing")
        }
    }

    func testFavoritesAreNotResettable() {
        XCTAssertFalse(SettingsReset.resettableCategories.contains("favorites"))
        XCTAssertEqual(SettingsReset.keysByCategory["favorites"], [])
    }

    /// The whole promise of the feature: a preferences reset never touches data.
    func testProtectedKeysAreNeverInAnyCategory() {
        for key in SettingsReset.allKeys {
            XCTAssertFalse(SettingsReset.protectedKeys.contains(key),
                           "\(key) is both reset and protected")
        }
    }

    func testCategoryKeysAreDisjoint() {
        var seen: [String: String] = [:]
        for id in SettingsReset.resettableCategories {
            for key in SettingsReset.keysByCategory[id] ?? [] {
                XCTAssertNil(seen[key], "\(key) claimed by both \(seen[key] ?? "") and \(id)")
                seen[key] = id
            }
        }
    }

    // MARK: - Resetting one category

    func testResetCategoryRemovesOnlyItsOwnKeys() {
        defaults.set(2, forKey: "IconSize")                 // appearance
        defaults.set(true, forKey: "ConfirmTrash")          // general
        defaults.set(["name"], forKey: "VisibleColumns")    // panels

        SettingsReset.reset(category: "appearance", in: defaults)

        XCTAssertNil(defaults.object(forKey: "IconSize"))
        XCTAssertNotNil(defaults.object(forKey: "ConfirmTrash"))
        XCTAssertNotNil(defaults.object(forKey: "VisibleColumns"))
    }

    func testResetShortcutsClearsPrefixedKeysOnly() {
        defaults.set("cmd+k", forKey: "kb.copy")
        defaults.set(true, forKey: "kb.off.move")
        defaults.set("Terminal", forKey: "TerminalApp")

        SettingsReset.reset(category: "shortcuts", in: defaults)

        XCTAssertNil(defaults.object(forKey: "kb.copy"))
        XCTAssertNil(defaults.object(forKey: "kb.off.move"))
        XCTAssertNotNil(defaults.object(forKey: "TerminalApp"))
    }

    func testResetUnknownCategoryIsANoOp() {
        defaults.set(2, forKey: "IconSize")
        SettingsReset.reset(category: "nope", in: defaults)
        XCTAssertNotNil(defaults.object(forKey: "IconSize"))
    }

    // MARK: - Resetting everything

    func testResetAllClearsPreferencesAndKeepsData() {
        // One preference from every resettable category…
        defaults.set(true, forKey: "ConfirmTrash")
        defaults.set(20, forKey: "IconSize")
        defaults.set(false, forKey: "ShowDriveBar")
        defaults.set(["refresh"], forKey: "ToolbarButtonIDs")
        defaults.set("cmd+k", forKey: "kb.copy")
        defaults.set(["fill": "112233"], forKey: "CommandLineColors.dark")
        // …and the data that must survive it.
        defaults.set([["path": "/tmp"]], forKey: "FavoriteItems")
        defaults.set([["kind": "sftp"]], forKey: "ServerConnections")
        defaults.set([["id": "custom.build", "command": "make"]], forKey: "CustomToolbarButtons")
        defaults.set("{{0,0},{100,100}}", forKey: "MainWindowFrame")
        defaults.set("/Users/me/work", forKey: "LeftPanelPath")

        SettingsReset.resetAll(in: defaults)

        for key in ["ConfirmTrash", "IconSize", "ShowDriveBar", "ToolbarButtonIDs",
                    "kb.copy", "CommandLineColors.dark"] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should have been reset")
        }
        for key in ["FavoriteItems", "ServerConnections", "CustomToolbarButtons",
                    "MainWindowFrame", "LeftPanelPath"] {
            XCTAssertNotNil(defaults.object(forKey: key), "\(key) must survive a reset")
        }
    }

    // MARK: - Command line colors

    func testCommandLineRoleDefaultsAreDistinct() {
        let roles = CommandLineColorRole.allCases
        XCTAssertEqual(roles.count, 3)
        XCTAssertEqual(Set(roles.map { $0.rawValue }).count, 3)
        XCTAssertEqual(Set(roles.map { $0.titleKey }).count, 3)
        // Fill sits under the border, so it must be the fainter tint.
        XCTAssertLessThan(CommandLineColorRole.fill.defaultColor.alphaComponent,
                          CommandLineColorRole.border.defaultColor.alphaComponent)
    }

    func testCommandLineColorKeysAreCoveredByTheAppearanceReset() {
        let appearance = SettingsReset.keysByCategory["appearance"] ?? []
        XCTAssertTrue(appearance.contains("CommandLineColors.light"))
        XCTAssertTrue(appearance.contains("CommandLineColors.dark"))
    }
}
