import XCTest
@testable import double_finder

final class QuickFilterTests: XCTestCase {
    func testPinyinInitials() {
        XCTAssertEqual(QuickFilter.initials(of: "测试"), "cs")
        XCTAssertEqual(QuickFilter.initials(of: "项目"), "xm")
        XCTAssertEqual(QuickFilter.initials(of: "Resources"), "resources")
        XCTAssertEqual(QuickFilter.initials(of: "测试report"), "csreport")
        XCTAssertEqual(QuickFilter.initials(of: "项目1"), "xm1")
    }

    func testPinyinMatch() {
        XCTAssertTrue(QuickFilter.matches(name: "测试", query: "cs"))
        XCTAssertTrue(QuickFilter.matches(name: "测试", query: "c"))
        XCTAssertTrue(QuickFilter.matches(name: "测试报告", query: "csbg"))
        XCTAssertTrue(QuickFilter.matches(name: "项目文档", query: "xm"))
        // Initials are first-letters only — "ce" (full pinyin of 测) must NOT match.
        XCTAssertFalse(QuickFilter.matches(name: "测试", query: "ce"))
        // substring on initials — "cs" matches 测试 anywhere in the name.
        XCTAssertTrue(QuickFilter.matches(name: "我的测试", query: "cs"))
    }

    func testLiteralSubstring() {
        XCTAssertTrue(QuickFilter.matches(name: "Resources", query: "re"))
        XCTAssertTrue(QuickFilter.matches(name: "README.md", query: "READ"))   // case-insensitive
        XCTAssertTrue(QuickFilter.matches(name: "README.md", query: "readme"))
        XCTAssertTrue(QuickFilter.matches(name: "Resources", query: "sources"), "substring matches anywhere")
        XCTAssertFalse(QuickFilter.matches(name: "Resources", query: "xyz"))
        // Typed CJK matches the literal name too.
        XCTAssertTrue(QuickFilter.matches(name: "测试", query: "测"))
    }

    func testEmptyQueryMatchesAll() {
        XCTAssertTrue(QuickFilter.matches(name: "anything", query: ""))
        XCTAssertTrue(QuickFilter.matches(name: "测试", query: ""))
    }
}
