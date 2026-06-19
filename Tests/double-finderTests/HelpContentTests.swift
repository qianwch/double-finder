import XCTest
@testable import double_finder

final class HelpContentTests: XCTestCase {

    /// The zh-Hans pack must contain every translation key the Help window uses,
    /// so no Help string silently falls back to English under Chinese UI.
    @MainActor func testAllHelpKeysExistInChinesePack() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "zh-Hans", withExtension: "json", subdirectory: "Localization"))
        let data = try Data(contentsOf: url)
        let pack = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: String])

        var keys: [String] = ["Help", "Double Finder Help", "Overview",
                              "Keyboard Shortcuts", "About", "Version", "License",
                              "Project Page", "Report an Issue",
                              HelpContent.customizeHintKey]
        for group in HelpContent.shortcutGroups {
            keys.append(group.titleKey)
            keys.append(contentsOf: group.shortcuts.map { $0.nameKey })
        }
        let missing = keys.filter { pack[$0] == nil }
        XCTAssertTrue(missing.isEmpty, "Missing zh-Hans translations: \(missing)")
    }

    /// Overview markdown loads and is non-empty for both Chinese and English UI.
    @MainActor func testOverviewMarkdownLoads() {
        Localizer.shared.setLanguage(.zhHans)
        XCTAssertGreaterThan(HelpContent.overviewMarkdown().count, 20)
        Localizer.shared.setLanguage(.en)
        XCTAssertGreaterThan(HelpContent.overviewMarkdown().count, 20)
    }

    /// Shortcut data is well-formed: groups non-empty, key strings present.
    func testShortcutGroupsWellFormed() {
        XCTAssertFalse(HelpContent.shortcutGroups.isEmpty)
        for g in HelpContent.shortcutGroups {
            XCTAssertFalse(g.shortcuts.isEmpty, "Group \(g.titleKey) is empty")
            for s in g.shortcuts {
                XCTAssertFalse(s.nameKey.isEmpty)
                XCTAssertFalse(s.keys.isEmpty)
            }
        }
    }

    func testURLsValid() {
        XCTAssertEqual(HelpContent.projectURL.absoluteString,
                       "https://github.com/qianwch/double-finder")
        XCTAssertEqual(HelpContent.issuesURL.absoluteString,
                       "https://github.com/qianwch/double-finder/issues")
    }
}
