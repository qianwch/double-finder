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

    func testDeeplyNestedBlockquoteDoesNotCrash() {
        // Hostile input: ~5000 quote levels used to segfault (unbounded recursion).
        let h = body(String(repeating: "> ", count: 5000) + "x")
        XCTAssertFalse(h.isEmpty)
        // Depth is capped: nowhere near 5000 blockquote levels in the output.
        XCTAssertTrue(h.components(separatedBy: "<blockquote>").count <= 66)
        // The overflow degrades to escaped paragraph text, not dropped content.
        XCTAssertTrue(h.contains("&gt;"))
    }

    func testCRLFNormalized() {
        let h = body("# T\r\n---\r\n")
        XCTAssertTrue(h.contains("<h1>T</h1>"))
        XCTAssertTrue(h.contains("<hr"))
    }

    // MARK: inline (Task 4)

    func testEmphasis() {
        let h = body("**bold** __bold__ *em* _em_ ~~del~~")
        XCTAssertEqual(h.components(separatedBy: "<strong>bold</strong>").count, 3)  // 两种定界各一次
        XCTAssertTrue(h.contains("<em>em</em>"))
        XCTAssertTrue(h.contains("<del>del</del>"))
    }

    func testInlineCodeNotParsedInside() {
        let h = body("use `**not bold**` here")
        XCTAssertTrue(h.contains("<code>**not bold**</code>"))
        XCTAssertFalse(h.contains("<strong>"))
    }

    func testBackslashEscape() {
        let h = body(#"\*literal\* stars"#)
        XCTAssertTrue(h.contains("*literal* stars"))
        XCTAssertFalse(h.contains("<em>"))
    }

    func testLink() {
        let h = body("[site](https://example.com)")
        XCTAssertTrue(h.contains("<a href=\"https://example.com\">site</a>"))
    }

    func testNestedEmphasisInStrong() {
        let h = body("**bold *and em***")
        XCTAssertTrue(h.contains("<strong>bold <em>and em</em></strong>"))
    }

    func testTableWithAlignment() {
        let h = body("| a | b |\n|:--|--:|\n| 1 | 2 |")
        XCTAssertTrue(h.contains("<table>"))
        XCTAssertTrue(h.contains("<th style=\"text-align:left\">a</th>"))
        XCTAssertTrue(h.contains("<td style=\"text-align:right\">2</td>"))
    }

    func testLocalImageBecomesDataURI() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])  // PNG magic 足矣
        try png.write(to: dir.appendingPathComponent("pic.png"))
        let h = MarkdownToHTML.render("![alt](pic.png)", baseDir: dir)
        XCTAssertTrue(h.contains("src=\"data:image/png;base64,"))
        XCTAssertTrue(h.contains("alt=\"alt\""))
    }

    func testMissingImagePlaceholder() {
        let h = MarkdownToHTML.render("![x](nope.png)", baseDir: FileManager.default.temporaryDirectory)
        XCTAssertTrue(h.contains("[image: nope.png]"))
        XCTAssertFalse(h.contains("<img"))
    }

    func testRemoteImagePassthrough() {
        let h = body("![r](https://example.com/i.png)")
        XCTAssertTrue(h.contains("src=\"https://example.com/i.png\""))
    }
}
