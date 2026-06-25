import XCTest
@testable import double_finder

final class VolumeSizeTests: XCTestCase {
    func testNoSplitCases() {
        XCTAssertEqual(VolumeSize.parse(""), .none)
        XCTAssertEqual(VolumeSize.parse("   "), .none)
        XCTAssertEqual(VolumeSize.parse("No split"), .none)
        XCTAssertEqual(VolumeSize.parse("  no split "), .none)   // case-insensitive
    }

    func testPresetLabels() {
        XCTAssertEqual(VolumeSize.parse("10 MB"), .token("10m"))
        XCTAssertEqual(VolumeSize.parse("100 MB"), .token("100m"))
        XCTAssertEqual(VolumeSize.parse("700 MB (CD)"), .token("700m"))    // parenthetical stripped
        XCTAssertEqual(VolumeSize.parse("4480 MB (DVD)"), .token("4480m"))
    }

    func testCustomForms() {
        XCTAssertEqual(VolumeSize.parse("250m"), .token("250m"))
        XCTAssertEqual(VolumeSize.parse("250M"), .token("250m"))          // unit case-insensitive
        XCTAssertEqual(VolumeSize.parse("250mb"), .token("250m"))
        XCTAssertEqual(VolumeSize.parse("250 mb"), .token("250m"))
        XCTAssertEqual(VolumeSize.parse("1g"), .token("1g"))
        XCTAssertEqual(VolumeSize.parse("512k"), .token("512k"))
        XCTAssertEqual(VolumeSize.parse("1048576"), .token("1048576b"))   // bare number = bytes
    }

    func testInvalid() {
        XCTAssertEqual(VolumeSize.parse("abc"), .invalid)
        XCTAssertEqual(VolumeSize.parse("1.5g"), .invalid)               // no fractions
        XCTAssertEqual(VolumeSize.parse("0"), .invalid)                  // must be positive
        XCTAssertEqual(VolumeSize.parse("10 tb"), .invalid)              // unknown unit
        XCTAssertEqual(VolumeSize.parse("m100"), .invalid)
    }

    func testLocalizedNoSplitLabelMapsToNone() {
        // Localized "No split" labels must parse as .none (regression: non-English
        // UI default was misread as .invalid, blocking Pack entirely).
        XCTAssertEqual(VolumeSize.parse("不分卷", noSplitLabel: "不分卷"), .none)
        XCTAssertEqual(VolumeSize.parse("Nicht teilen", noSplitLabel: "Nicht teilen"), .none)
        XCTAssertEqual(VolumeSize.parse("  不分卷 ", noSplitLabel: "不分卷"), .none)  // trimmed
        // English still works through the overload too.
        XCTAssertEqual(VolumeSize.parse("No split", noSplitLabel: "不分卷"), .none)
    }

    func testLabelOverloadStillParsesRealSizes() {
        // A real size is parsed normally even when a non-matching label is supplied.
        XCTAssertEqual(VolumeSize.parse("100 MB", noSplitLabel: "不分卷"), .token("100m"))
        XCTAssertEqual(VolumeSize.parse("250m", noSplitLabel: "Nicht teilen"), .token("250m"))
        XCTAssertEqual(VolumeSize.parse("garbage", noSplitLabel: "不分卷"), .invalid)
    }
}
