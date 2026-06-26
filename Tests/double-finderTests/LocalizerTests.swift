import XCTest
@testable import double_finder

final class LocalizerTests: XCTestCase {

    // resolved(from:) maps system languages to a concrete built-in language.
    func testSystemResolution() {
        XCTAssertEqual(Language.resolved(from: ["zh-Hans-US", "en"]), .zhHans)
        XCTAssertEqual(Language.resolved(from: ["zh-Hant-TW"]), .en)   // Traditional → English
        XCTAssertEqual(Language.resolved(from: ["ja-JP"]), .ja)
        XCTAssertEqual(Language.resolved(from: ["ko"]), .ko)
        XCTAssertEqual(Language.resolved(from: ["de-DE"]), .de)
        XCTAssertEqual(Language.resolved(from: ["fr"]), .fr)
        XCTAssertEqual(Language.resolved(from: ["pt-BR"]), .en)        // unsupported → English
        XCTAssertEqual(Language.resolved(from: []), .en)
    }

    func testJsonNameMapping() {
        XCTAssertEqual(Language.zhHans.jsonName, "zh-Hans")
        XCTAssertNil(Language.en.jsonName)
        XCTAssertNil(Language.system.jsonName)
    }

    // English (no pack) falls back to the key verbatim.
    @MainActor func testEnglishIdentity() {
        Localizer.shared.setLanguage(.en)
        XCTAssertEqual(tr("File"), "File")
        XCTAssertEqual(tr("A String With No Translation Anywhere"),
                       "A String With No Translation Anywhere")
    }

    // A concrete pack translates a seeded key and falls back for unknown keys.
    @MainActor func testPackLookupAndFallback() {
        Localizer.shared.setLanguage(.ja)
        XCTAssertEqual(tr("File"), "ファイル")
        XCTAssertEqual(tr("Totally Unknown Key 123"), "Totally Unknown Key 123")
    }

    // Format variant applies String(format:) after translation.
    @MainActor func testFormat() {
        Localizer.shared.setLanguage(.en)
        XCTAssertEqual(tr("%d items selected", 3), "3 items selected")
    }

    // Context-disambiguated keys: the F3 "View" action vs the "View" menu need
    // different translations of the same English word.
    @MainActor func testContextKeyDisambiguation() {
        Localizer.shared.setLanguage(.zhHans)
        XCTAssertEqual(tr(ctxKey("View", "f3")), "查看", "F3 View should be 查看")
        XCTAssertEqual(tr("View"), "视图", "View menu should stay 视图")

        Localizer.shared.setLanguage(.de)
        XCTAssertEqual(tr(ctxKey("View", "f3")), "Ansehen")
        XCTAssertEqual(tr("View"), "Ansicht")

        // English / unknown context falls back to the base word.
        Localizer.shared.setLanguage(.en)
        XCTAssertEqual(tr(ctxKey("View", "f3")), "View")
        Localizer.shared.setLanguage(.zhHans)
        XCTAssertEqual(tr(ctxKey("View", "no-such-context")), "View",
                       "unknown context with no entry falls back to base, not the menu translation")
    }
}
