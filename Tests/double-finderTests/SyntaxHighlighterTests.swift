import XCTest
@testable import double_finder

final class SyntaxHighlighterTests: XCTestCase {
    private func kinds(_ text: String, _ ext: String) -> [(String, TokenKind)] {
        let spec = LanguageSpec.language(forExtension: ext)!
        let ns = text as NSString
        return SyntaxHighlighter.tokenize(text, spec: spec)
            .map { (ns.substring(with: $0.range), $0.kind) }
    }

    func testKeywordWordBoundary() {
        let t = kinds("for format in information { }", "swift")
        XCTAssertEqual(t.filter { $0.1 == .keyword }.map(\.0), ["for", "in"])  // format/information 不染
    }

    func testStringWithEscape() {
        let t = kinds(#"let s = "a\"b" + x"#, "swift")
        XCTAssertTrue(t.contains { $0.0 == #""a\"b""# && $0.1 == .string })
    }

    func testUnterminatedStringStopsAtEOL() {
        let t = kinds("let s = \"open\nlet y = 1", "swift")
        XCTAssertTrue(t.contains { $0.0 == "\"open" && $0.1 == .string })  // 止损行尾
        XCTAssertTrue(t.contains { $0.0 == "let" && $0.1 == .keyword })    // 下一行照常
    }

    func testLineComment() {
        let t = kinds("x = 1  # note: for real\ny = 2", "py")
        XCTAssertTrue(t.contains { $0.0 == "# note: for real" && $0.1 == .comment })
        XCTAssertFalse(t.contains { $0.0 == "for" && $0.1 == .keyword })   // 注释内不再识别
    }

    func testBlockCommentSpansLines() {
        let t = kinds("a /* one\ntwo */ let", "swift")
        XCTAssertTrue(t.contains { $0.0 == "/* one" && $0.1 == .comment })
        XCTAssertTrue(t.contains { $0.0 == "two */" && $0.1 == .comment })
        XCTAssertTrue(t.contains { $0.0 == "let" && $0.1 == .keyword })
    }

    func testUnterminatedBlockCommentRunsToEnd() {
        let t = kinds("/* open\nstill", "swift")
        XCTAssertEqual(t.filter { $0.1 == .comment }.map(\.0), ["/* open", "still"])
    }

    func testNumbers() {
        let t = kinds("x = 42 + 3.14 + 0xFF, id2 = 7", "swift")
        XCTAssertEqual(t.filter { $0.1 == .number }.map(\.0), ["42", "3.14", "0xFF", "7"])  // id2 里的 2 不染
    }

    func testYAMLKeyRule() {
        let t = kinds("name: value\n  nested_key: 1\n# c", "yaml")
        XCTAssertTrue(t.contains { $0.0 == "name" && $0.1 == .keyword })
        XCTAssertTrue(t.contains { $0.0 == "nested_key" && $0.1 == .keyword })
    }

    func testMarkdownLineRules() {
        let t = kinds("# Title\n> quote\n```swift\nplain", "md")
        XCTAssertTrue(t.contains { $0.0 == "# Title" && $0.1 == .keyword })
        XCTAssertTrue(t.contains { $0.0 == "> quote" && $0.1 == .comment })
        XCTAssertTrue(t.contains { $0.0 == "```swift" && $0.1 == .string })
    }

    func testUTF16RangesWithCJK() {
        // "变量" 占 2 个 utf16 unit——keyword range 必须落在正确位置
        let text = "变量 let x"
        let ns = text as NSString
        let toks = SyntaxHighlighter.tokenize(text, spec: LanguageSpec.language(forExtension: "swift")!)
        let kw = toks.first { $0.kind == .keyword }
        XCTAssertNotNil(kw)
        XCTAssertEqual(ns.substring(with: kw!.range), "let")
    }

    func testEmptyInput() {
        XCTAssertTrue(SyntaxHighlighter.tokenize("", spec: LanguageSpec.language(forExtension: "swift")!).isEmpty)
    }

    func testYAMLCommentLineWithColonIsNotKey() {
        // "#" is not a key char, so keyEnd must bail before the line-comment
        // branch gets a chance to run — pins the strict keyEnd contract.
        let t = kinds("# url: http://x", "yaml")
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.first?.0, "# url: http://x")
        XCTAssertEqual(t.first?.1, .comment)
        XCTAssertFalse(t.contains { $0.1 == .keyword })
    }

    func testCRLFLineEndings() {
        let t = kinds("let a = 1\r\nlet b = 2", "swift")
        let keywords = t.filter { $0.1 == .keyword }.map(\.0)
        XCTAssertEqual(keywords, ["let", "let"])
        XCTAssertTrue(keywords.allSatisfy { !$0.contains("\r") })

        let numbers = t.filter { $0.1 == .number }
        XCTAssertEqual(numbers.map(\.0), ["1", "2"])
        XCTAssertTrue(numbers.allSatisfy { !$0.0.contains("\r") })
    }
}
