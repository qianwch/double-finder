import XCTest
@testable import double_finder

final class MarkdownToHTMLTests: XCTestCase {
    private func body(_ md: String) -> String { MarkdownToHTML.render(md, baseDir: nil) }

    func testHeadings() {
        let h = body("# One\n### Three")
        XCTAssertTrue(h.contains("<h1>One</h1>"))
        XCTAssertTrue(h.contains("<h3>Three</h3>"))
    }

    func testParagraphLazyJoin() {
        let h = body("line a\nline b\n\nsecond para")
        XCTAssertTrue(h.contains("<p>line a\nline b</p>"))
        XCTAssertTrue(h.contains("<p>second para</p>"))
    }

    func testFencedCodeBlockHighlighted() {
        let h = body("```swift\nlet x = 1\n```")
        XCTAssertTrue(h.contains("<pre><code"))
        XCTAssertTrue(h.contains("<span class=\"kw\">let</span>"))   // 复用 SyntaxHighlighter
        XCTAssertTrue(h.contains("<span class=\"num\">1</span>"))
    }

    func testFencedCodeBlockUnknownLangPlain() {
        let h = body("```whatever\n<tag> & stuff\n```")
        XCTAssertTrue(h.contains("&lt;tag&gt; &amp; stuff"))          // 转义、无 span
        XCTAssertFalse(h.contains("<span class="))
    }

    func testUnterminatedFenceRunsToEnd() {
        let h = body("```\ncode line")
        XCTAssertTrue(h.contains("code line"))
        XCTAssertTrue(h.contains("<pre><code"))
    }

    func testBlockquoteNested() {
        let h = body("> outer\n> > inner")
        XCTAssertTrue(h.contains("<blockquote>"))
        // 嵌套：出现两层 blockquote
        XCTAssertTrue(h.components(separatedBy: "<blockquote>").count >= 3)
    }

    func testUnorderedAndOrderedLists() {
        let h = body("- a\n- b\n\n1. x\n2. y")
        XCTAssertTrue(h.contains("<ul>"))
        XCTAssertTrue(h.contains("<li>a</li>"))
        XCTAssertTrue(h.contains("<ol>"))
        XCTAssertTrue(h.contains("<li>x</li>"))
    }

    func testNestedListByIndent() {
        let h = body("- parent\n  - child")
        // child 的 <ul> 嵌在 parent 的 <li> 内
        XCTAssertTrue(h.contains("<li>parent<ul><li>child</li></ul></li>")
                   || h.contains("<li>parent\n<ul><li>child</li></ul></li>"))
    }

    func testTaskList() {
        let h = body("- [x] done\n- [ ] todo")
        XCTAssertTrue(h.contains("checked"))
        XCTAssertTrue(h.contains("type=\"checkbox\""))
        XCTAssertTrue(h.contains("disabled"))
    }

    func testHorizontalRule() {
        XCTAssertTrue(body("---").contains("<hr"))
        XCTAssertTrue(body("***").contains("<hr"))
    }

    func testRawHTMLEscaped() {
        let h = body("<script>alert(1)</script>")
        XCTAssertFalse(h.contains("<script>"))
        XCTAssertTrue(h.contains("&lt;script&gt;"))
    }

    func testEmptyInput() {
        let h = body("")
        XCTAssertTrue(h.contains("<body>"))
    }
}
