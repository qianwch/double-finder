import XCTest
import AppKit
@testable import double_finder

final class AppearanceTests: XCTestCase {

    func testAppKitNameMapping() {
        XCTAssertNil(AppAppearance.system.appKitName)
        XCTAssertEqual(AppAppearance.light.appKitName, .aqua)
        XCTAssertEqual(AppAppearance.dark.appKitName, .darkAqua)
    }

    func testRawValueRoundTrip() {
        XCTAssertEqual(AppAppearance(rawValue: ""), .system)
        XCTAssertEqual(AppAppearance(rawValue: "light"), .light)
        XCTAssertEqual(AppAppearance(rawValue: "dark"), .dark)
        XCTAssertNil(AppAppearance(rawValue: "bogus"))
    }

    func testAllCasesOrder() {
        XCTAssertEqual(AppAppearance.allCases, [.system, .light, .dark])
    }

    /// Unknown / absent stored value resolves to .system.
    func testSettingDefaultsToSystem() {
        UserDefaults.standard.removeObject(forKey: "Appearance")
        XCTAssertEqual(AppSettings.appearance, .system)
        UserDefaults.standard.set("dark", forKey: "Appearance")
        XCTAssertEqual(AppSettings.appearance, .dark)
        UserDefaults.standard.set("garbage", forKey: "Appearance")
        XCTAssertEqual(AppSettings.appearance, .system)
        UserDefaults.standard.removeObject(forKey: "Appearance")
    }
}
