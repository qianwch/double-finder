import XCTest
@testable import double_finder

// MARK: - EbookHTML (sanitizer / page assembly)

final class EbookHTMLTests: XCTestCase {

    private func context(chapter: Int = 0,
                         resource: @escaping (String) -> String? = { _ in nil },
                         link: @escaping (String) -> String? = { _ in nil }) -> EbookHTML.Context {
        EbookHTML.Context(chapterIndex: chapter, resolveResource: resource, resolveLink: link)
    }

    func testScriptsFramesAndEventHandlersAreRemoved() {
        let html = """
        <p onclick="x()">Hi</p><script>alert(1)</script><iframe src="x"></iframe>\
        <!-- comment --><b>ok</b><img src="a.png" onerror="evil()">
        """
        let out = EbookHTML.sanitizeBody(html, context: context(resource: { _ in "data:image/png;base64,AA==" }))
        XCTAssertFalse(out.contains("<script"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertFalse(out.contains("<iframe"))
        XCTAssertFalse(out.contains("onclick"))
        XCTAssertFalse(out.contains("onerror"))
        XCTAssertFalse(out.contains("comment"))
        XCTAssertTrue(out.contains("<b>ok</b>"))
        XCTAssertTrue(out.contains("src=\"data:image/png;base64,AA==\""))
    }

    func testIdsArePrefixedAndLinksResolved() {
        let html = "<h1 id=\"top\">T</h1><a href=\"ch2.xhtml#sec\">go</a><a href=\"http://x.y/z\">ext</a><a href=\"mailto:a@b\">m</a>"
        let out = EbookHTML.sanitizeBody(html, context: context(chapter: 3, link: { href in
            if href.hasPrefix("http") { return href }
            if href == "ch2.xhtml#sec" { return "#c4-sec" }
            return nil
        }))
        XCTAssertTrue(out.contains("id=\"c3-top\""))
        XCTAssertTrue(out.contains("href=\"#c4-sec\""))
        XCTAssertTrue(out.contains("href=\"http://x.y/z\""))
        XCTAssertTrue(out.contains("<a>m</a>"), out)          // unresolvable link keeps its text, loses href
    }

    func testMissingImageBecomesPlaceholder() {
        let out = EbookHTML.sanitizeBody("<img src=\"pics/gone.jpg\" alt=\"x\"/>", context: context())
        XCTAssertTrue(out.contains("ebook-missing"))
        XCTAssertTrue(out.contains("gone.jpg"))
        XCTAssertFalse(out.contains("<img"))
    }

    func testUnknownTagsAndTextPassThroughUntouched() {
        let html = "<div class=\"a\">中文 &amp; <mbp:nu>x</mbp:nu></div>"
        XCTAssertEqual(EbookHTML.sanitizeBody(html, context: context()), html)
    }

    func testStyleInsideBodyIsKeptWithRewrittenURLs() {
        let out = EbookHTML.sanitizeBody("<style>p{background:url(bg.png)}</style><p>x</p>",
                                         context: context(resource: { $0 == "bg.png" ? "data:image/png;base64,QQ==" : nil }))
        XCTAssertTrue(out.contains("url(\"data:image/png;base64,QQ==\")"))
    }

    func testSplitDocumentAndStylesheets() {
        let doc = """
        <?xml version="1.0"?><!DOCTYPE html><html><head><title>t</title>\
        <link rel="stylesheet" href="../s.css"/><style>h1{}</style></head><body class="b"><p>hi</p></body></html>
        """
        let parts = EbookHTML.splitDocument(doc)
        XCTAssertEqual(parts.body, "<p>hi</p>")
        let styles = EbookHTML.stylesheets(inHead: parts.head)
        XCTAssertEqual(styles.links, ["../s.css"])
        XCTAssertEqual(styles.inline, ["h1{}"])
        // A bare fragment is the body.
        XCTAssertEqual(EbookHTML.splitDocument("<p>x</p>").body, "<p>x</p>")
    }

    func testRewriteCSSDropsImportsAndInlinesFonts() {
        let css = "@import url(other.css); @font-face { src: url('f.otf') } p { background: url(\"missing.png\") }"
        let out = EbookHTML.rewriteCSS(css) { $0 == "f.otf" ? "data:font/otf;base64,AA==" : nil }
        XCTAssertFalse(out.contains("@import"))
        XCTAssertTrue(out.contains("url(\"data:font/otf;base64,AA==\")"))
        XCTAssertTrue(out.contains("background: none"))
    }

    func testResolveRelativePaths() {
        XCTAssertEqual(EbookHTML.resolve(ref: "../img/a%20b.png", relativeTo: "OEBPS/text/ch1.xhtml")?.path, "OEBPS/img/a b.png")
        let r = EbookHTML.resolve(ref: "ch2.xhtml#sec", relativeTo: "OEBPS/ch1.xhtml")
        XCTAssertEqual(r?.path, "OEBPS/ch2.xhtml")
        XCTAssertEqual(r?.fragment, "sec")
        XCTAssertEqual(EbookHTML.resolve(ref: "#here", relativeTo: "a/b.xhtml")?.path, "a/b.xhtml")
        XCTAssertNil(EbookHTML.resolve(ref: "https://x/y", relativeTo: "a.xhtml"))
    }

    func testMimeSniffBeatsExtension() {
        XCTAssertEqual(EbookHTML.mimeType(for: Data([0xFF, 0xD8, 0xFF, 0xE0]), hint: "x.png"), "image/jpeg")
        XCTAssertEqual(EbookHTML.mimeType(for: Data([0x89, 0x50, 0x4E, 0x47]), hint: ""), "image/png")
        XCTAssertEqual(EbookHTML.mimeType(for: Data("<svg/>".utf8), hint: "a.svg"), "image/svg+xml")
        XCTAssertEqual(EbookHTML.mimeType(for: Data([1, 2]), hint: "f.woff2"), "font/woff2")
    }

    func testPageHasSidebarChaptersAndEscapedTitle() {
        var book = EbookBook(title: "A <b>", author: "Me", formatName: "EPUB")
        book.chapters = [EbookChapter(index: 0, html: "<p>one</p>"), EbookChapter(index: 1, html: "<p>two</p>")]
        book.toc = [EbookTOCEntry(title: "Two", depth: 1, anchor: "ch-1")]
        book.css = ["p{color:red}</style><script>x</script>"]
        let page = EbookHTML.page(for: book)
        XCTAssertTrue(page.contains("<title>A &lt;b&gt;</title>"))
        XCTAssertTrue(page.contains("id=\"ch-0\""))
        XCTAssertTrue(page.contains("id=\"ch-1\""))
        XCTAssertTrue(page.contains("<li class=\"d1\"><a href=\"#ch-1\">Two</a></li>"))
        XCTAssertFalse(page.contains("</style><script>"), "book CSS must not be able to close our style block")
    }
}

// MARK: - MOBI building blocks

final class MOBIDecompressTests: XCTestCase {

    func testPalmDocLiteralSpaceAndBackReference() {
        // "abc" literal run, then 0xE1 = space + 'a', then a back-reference of
        // length 3 at distance 4 (pair: 0x8000 | distance<<3 | (len-3)).
        let distance = 4, len = 3
        let pair = 0x8000 | (distance << 3) | (len - 3)
        let data: [UInt8] = [3, 0x61, 0x62, 0x63, 0xE1, UInt8(pair >> 8), UInt8(pair & 0xFF)]
        XCTAssertEqual(String(decoding: PalmDoc.decompress(data), as: UTF8.self), "abc abc ")
    }

    func testPalmDocIgnoresCorruptBackReference() {
        XCTAssertEqual(PalmDoc.decompress([0x80, 0x20]), [])          // distance 4 with nothing to copy
        XCTAssertEqual(PalmDoc.decompress([0x41, 0x80]), [0x41])      // truncated pair
    }

    func testTrailingEntriesMultibyteAndTBS() {
        // flags=3: TBS entry of 1 byte (0x81 → size 1), then multibyte count (0x00 & 3) + 1 = 1.
        XCTAssertEqual(MOBITrailing.size(of: [0x41, 0x42, 0x00, 0x81], flags: 3), 2)
        XCTAssertEqual(MOBITrailing.size(of: [0x41, 0x42], flags: 0), 0)
        XCTAssertEqual(MOBITrailing.size(of: [0x03], flags: 1), 1)     // never more than the record itself
    }

    func testVarintAndBase32() {
        XCTAssertEqual(MOBIVarint.read([0x81], at: 0)?.value, 1)
        XCTAssertEqual(MOBIVarint.read([0x01, 0x80], at: 0)?.value, 128)
        XCTAssertEqual(MOBIVarint.read([0x01, 0x02, 0x83], at: 0)?.consumed, 3)
        XCTAssertNil(MOBIVarint.read([0x01], at: 0))                   // no terminator
        XCTAssertEqual(KindleBase32.decode("000O"), 24)
        XCTAssertEqual(KindleBase32.decode("0010"), 32)
        XCTAssertNil(KindleBase32.decode("00Z0"))
    }

    func testHuffCdicRejectsGarbage() {
        XCTAssertNil(HuffCdic(huff: Array("HUFF".utf8), cdics: []))
        XCTAssertNil(HuffCdic(huff: [UInt8](repeating: 0, count: 2000), cdics: [[UInt8](repeating: 0, count: 64)]))
    }
}

// MARK: - Synthetic MOBI7 file

final class MOBIReaderTests: XCTestCase {

    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// Builds a minimal uncompressed MOBI7 with one text record and one PNG-ish image.
    private func makeMOBI(text: String, title: String = "Synthetic", author: String = "Tester") -> [UInt8] {
        var r0 = [UInt8](repeating: 0, count: 16 + 0xE8)
        r0.replaceSubrange(0..<2, with: be16(1))                       // compression: none
        r0.replaceSubrange(4..<8, with: be32(text.utf8.count))
        r0.replaceSubrange(8..<10, with: be16(1))                      // 1 text record
        r0.replaceSubrange(10..<12, with: be16(4096))
        r0.replaceSubrange(16..<20, with: Array("MOBI".utf8))
        r0.replaceSubrange(20..<24, with: be32(0xE8))                  // header length
        r0.replaceSubrange(24..<28, with: be32(2))                     // mobi type: book
        r0.replaceSubrange(28..<32, with: be32(65001))                 // utf-8
        r0.replaceSubrange(36..<40, with: be32(6))                     // version 6
        r0.replaceSubrange(0x6C..<0x70, with: be32(2))                 // first image = record 2
        r0.replaceSubrange(0x80..<0x84, with: be32(0x40))              // EXTH present
        r0.replaceSubrange(0xF4..<0xF8, with: be32(0xFFFF_FFFF))       // no NCX
        // EXTH: 100 author, 503 title
        var exth: [UInt8] = []
        for (tag, value) in [(100, author), (503, title)] {
            exth += be32(tag) + be32(8 + value.utf8.count) + Array(value.utf8)
        }
        r0 += Array("EXTH".utf8) + be32(12 + exth.count) + be32(2) + exth
        let rec1 = Array(text.utf8)
        let rec2: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0]
        let records = [r0, rec1, rec2]
        var pdb = [UInt8](repeating: 0, count: 78)
        pdb.replaceSubrange(0..<9, with: Array("synthetic".utf8))
        pdb.replaceSubrange(60..<68, with: Array("BOOKMOBI".utf8))
        pdb.replaceSubrange(76..<78, with: be16(records.count))
        var offset = 78 + records.count * 8 + 2
        for (i, r) in records.enumerated() {
            pdb += be32(offset) + [0, 0, 0, UInt8(i)]
            offset += r.count
        }
        pdb += [0, 0]
        for r in records { pdb += r }
        return pdb
    }

    func testMOBI7ChaptersLinksImagesAndMetadata() throws {
        let head = "<html><head></head><body><h1>One</h1><p>Hello <a filepos=0000000000>link</a></p><mbp:pagebreak/>"
        var text = head + "<h2>Two</h2><img recindex=\"00001\"/></body></html>"
        // Point the filepos at "<h2>" (the character index == byte index: all ASCII).
        let target = head.utf8.count
        text = text.replacingOccurrences(of: "filepos=0000000000", with: String(format: "filepos=%010d", target))
        let book = try MOBIReader.read(bytes: makeMOBI(text: text), name: "x")
        XCTAssertEqual(book.formatName, "MOBI")
        XCTAssertEqual(book.title, "Synthetic")
        XCTAssertEqual(book.author, "Tester")
        XCTAssertEqual(book.chapters.count, 2, "cut at the page break")
        XCTAssertTrue(book.chapters[0].html.contains("<h1>One</h1>"))
        XCTAssertTrue(book.chapters[1].html.contains("<h2>Two</h2>"))
        // The text after the page break moved: filepos was computed on the ORIGINAL
        // string, whose "filepos=0000000000" placeholder has the same length, so the
        // anchor sits at the start of chapter 2.
        XCTAssertTrue(book.chapters[0].html.contains("href=\"#c1-fp\(target)\""), book.chapters[0].html)
        XCTAssertTrue(book.chapters[1].html.contains("id=\"c1-fp\(target)\""), book.chapters[1].html)
        XCTAssertTrue(book.chapters[1].html.contains("src=\"data:image/png;base64,"))
        XCTAssertFalse(book.chapters[1].html.contains("recindex"))
        XCTAssertFalse(book.chapters[1].html.contains("mbp:"))
    }

    func testEncryptedBookIsReportedAsDRM() {
        var bytes = makeMOBI(text: "<html><body>x</body></html>")
        // record 0 starts right after the record list (3 records × 8 + 78 + 2 pad)
        let r0 = 78 + 3 * 8 + 2
        bytes[r0 + 13] = 2                                              // encryption type
        XCTAssertThrowsError(try MOBIReader.read(bytes: bytes, name: "x")) { error in
            guard case EbookError.drm = error else { return XCTFail("expected drm, got \(error)") }
        }
    }

    func testGarbageNeverTraps() {
        XCTAssertThrowsError(try MOBIReader.read(bytes: [1, 2, 3], name: "x"))
        XCTAssertThrowsError(try MOBIReader.read(bytes: Array("CONT\u{2}garbage".utf8) + [UInt8](repeating: 0, count: 100), name: "x")) { error in
            guard case EbookError.unsupported(let what) = error, what == "KFX" else { return XCTFail("\(error)") }
        }
        var bytes = makeMOBI(text: "<html><body>x</body></html>")
        // Corrupt the record offsets: must throw, not crash.
        bytes[80] = 0xFF
        XCTAssertThrowsError(try MOBIReader.read(bytes: bytes, name: "x"))
    }
}

// MARK: - Synthetic EPUB tree

final class EPUBReaderTests: XCTestCase {

    private var root = ""

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "epubtest-\(ProcessInfo.processInfo.globallyUniqueString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/META-INF", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/OEBPS/img", withIntermediateDirectories: true)
        func write(_ rel: String, _ s: String) throws { try s.write(toFile: root + "/" + rel, atomically: true, encoding: .utf8) }
        try write("META-INF/container.xml", """
        <?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)
        try write("OEBPS/content.opf", """
        <?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Test Book</dc:title><dc:creator>Ann</dc:creator>
        <meta name="cover" content="cov"/></metadata>
        <manifest>
          <item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          <item id="c2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="css" href="style.css" media-type="text/css"/>
          <item id="cov" href="img/cover.png" media-type="image/png"/>
          <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        </manifest>
        <spine toc="ncx"><itemref idref="c1"/><itemref idref="c2"/></spine></package>
        """)
        try write("OEBPS/ch1.xhtml", """
        <html><head><link rel="stylesheet" href="style.css"/></head>
        <body><h1 id="start">Chapter 1</h1><p>See <a href="ch2.xhtml#s2">section 2</a>&nbsp;now</p>
        <img src="img/cover.png"/><script>bad()</script></body></html>
        """)
        try write("OEBPS/ch2.xhtml", "<html><body><h1>Chapter 2</h1><h2 id=\"s2\">Section</h2></body></html>")
        try write("OEBPS/nav.xhtml", """
        <html xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol>
        <li><a href="ch1.xhtml">One</a></li>
        <li><a href="ch2.xhtml">Two</a><ol><li><a href="ch2.xhtml#s2">Two&nbsp;point one</a></li></ol></li>
        </ol></nav></body></html>
        """)
        try write("OEBPS/style.css", "p { color: red } h1 { background: url(img/cover.png) }")
        try Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]).write(to: URL(fileURLWithPath: root + "/OEBPS/img/cover.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    func testBuildsChaptersTOCCoverAndCSS() throws {
        let book = try EPUBReader.build(root: root)
        XCTAssertEqual(book.title, "Test Book")
        XCTAssertEqual(book.author, "Ann")
        XCTAssertEqual(book.formatName, "EPUB")
        XCTAssertEqual(book.chapters.count, 2)
        XCTAssertNotNil(book.coverDataURI)
        XCTAssertTrue(book.coverDataURI?.hasPrefix("data:image/png;base64,") ?? false)
        // Cross-chapter link → prefixed id in chapter 1; own ids prefixed too.
        XCTAssertTrue(book.chapters[0].html.contains("href=\"#c1-s2\""), book.chapters[0].html)
        XCTAssertTrue(book.chapters[1].html.contains("id=\"c1-s2\""))
        XCTAssertTrue(book.chapters[0].html.contains("id=\"c0-start\""))
        XCTAssertTrue(book.chapters[0].html.contains("src=\"data:image/png;base64,"))
        XCTAssertFalse(book.chapters[0].html.contains("<script"))
        // CSS collected once, url() inlined.
        XCTAssertEqual(book.css.count, 1)
        XCTAssertTrue(book.css[0].contains("url(\"data:image/png;base64,"))
        // EPUB3 nav wins; nesting preserved; &nbsp; survives the XML parse.
        XCTAssertEqual(book.toc.map { $0.title }, ["One", "Two", "Two point one"])   // nbsp collapses to a space
        XCTAssertEqual(book.toc.map { $0.depth }, [0, 0, 1])
        XCTAssertEqual(book.toc.map { $0.anchor }, ["ch-0", "ch-1", "c1-s2"])
    }

    func testFallsBackToNCXWhenNavMissing() throws {
        try FileManager.default.removeItem(atPath: root + "/OEBPS/nav.xhtml")
        try """
        <?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
        <navPoint id="a"><navLabel><text>First</text></navLabel><content src="ch1.xhtml"/>
          <navPoint id="b"><navLabel><text>Deep</text></navLabel><content src="ch2.xhtml#s2"/></navPoint></navPoint>
        </navMap></ncx>
        """.write(toFile: root + "/OEBPS/toc.ncx", atomically: true, encoding: .utf8)
        let book = try EPUBReader.build(root: root)
        XCTAssertEqual(book.toc.map { $0.title }, ["First", "Deep"])
        XCTAssertEqual(book.toc.map { $0.depth }, [0, 1])
        XCTAssertEqual(book.toc.last?.anchor, "c1-s2")
    }

    func testEncryptionManifestMeansDRM() throws {
        try """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">
        <CipherData><CipherReference URI="OEBPS/ch1.xhtml"/></CipherData></EncryptedData></encryption>
        """.write(toFile: root + "/META-INF/encryption.xml", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EPUBReader.build(root: root)) { error in
            guard case EbookError.drm = error else { return XCTFail("\(error)") }
        }
    }

    func testMissingContainerIsCorruptNotCrash() throws {
        try FileManager.default.removeItem(atPath: root + "/META-INF/container.xml")
        XCTAssertThrowsError(try EPUBReader.build(root: root)) { error in
            guard case EbookError.corrupt = error else { return XCTFail("\(error)") }
        }
    }
}
