import Foundation

// MARK: - Model

/// One entry of the book's navigation tree, flattened (depth = nesting level).
/// `anchor` is an element id in the rendered page (`ch-3` = a chapter's section,
/// `c3-intro` = a prefixed in-chapter id).
struct EbookTOCEntry: Equatable {
    let title: String
    let depth: Int
    let anchor: String
}

/// One reading unit — an EPUB spine item, a KF8 part, or a MOBI7 slice between
/// two navigation points. `html` is the ALREADY sanitized body content.
struct EbookChapter {
    let index: Int
    let html: String

    /// Section id in the rendered page.
    var anchor: String { EbookHTML.chapterAnchor(index) }
}

/// A parsed book, format-agnostic — the readers (EPUB / MOBI) produce it, the
/// page assembler renders it.
struct EbookBook {
    var title: String
    var author: String?
    var formatName: String                 // "EPUB" / "MOBI" / "KF8" — shown in the header
    var coverDataURI: String?
    var css: [String] = []                 // book stylesheets, already resource-rewritten
    var chapters: [EbookChapter] = []
    var toc: [EbookTOCEntry] = []
}

/// Failure classes the viewer turns into status-bar notes (English source
/// strings; `tr()` at the display site).
enum EbookError: Error {
    case drm                               // encrypted MOBI/AZW or EPUB with DRM markers
    case unsupported(String)               // e.g. KFX container
    case corrupt(String)                   // parse failure (never a crash)
    case cancelled
}

/// Total-inline budget for images / fonts embedded as data URIs. A comic-style
/// book could otherwise produce a multi-hundred-MB page that WKWebView chokes
/// on; past the budget images become a grey placeholder.
final class EbookResourceBudget {
    static let perItemMax = 8 << 20
    private(set) var remaining: Int
    init(total: Int = 48 << 20) { remaining = total }

    /// Reserve `bytes`; false when it does not fit.
    func take(_ bytes: Int) -> Bool {
        guard bytes <= Self.perItemMax, bytes <= remaining else { return false }
        remaining -= bytes
        return true
    }
}

// MARK: - HTML tooling

/// Pure, single-pass HTML rewriting for untrusted ebook content, plus the final
/// page assembly (CSS-only table-of-contents sidebar — the Lister web view has
/// JavaScript disabled, so navigation is plain `#anchor` links).
enum EbookHTML {

    static func chapterAnchor(_ index: Int) -> String { "ch-\(index)" }
    /// In-chapter ids are prefixed per chapter so two chapters with `id="top"`
    /// never collide once concatenated into one page.
    static func prefixedID(chapter: Int, id: String) -> String { "c\(chapter)-\(id)" }

    /// Per-chapter rewriting hooks.
    struct Context {
        let chapterIndex: Int
        /// `src` / `xlink:href` / `poster` / CSS `url()` reference → data URI, or
        /// nil when it cannot be resolved (→ placeholder).
        let resolveResource: (String) -> String?
        /// `<a href>` → an in-page `#anchor` or an absolute http(s) URL; nil drops
        /// the href (the link stays as plain text).
        let resolveLink: (String) -> String?
    }

    // MARK: Document splitting

    /// Splits an (X)HTML document into head content and body inner HTML. A
    /// fragment without `<body>` is returned whole as the body; the XML prolog
    /// and DOCTYPE never leak into the page.
    static func splitDocument(_ doc: String) -> (head: String, body: String) {
        let lower = doc.lowercased()      // ASCII case-fold; offsets line up 1:1 with `doc`
        var head = ""
        if let hs = lower.range(of: "<head"), let hsEnd = lower[hs.upperBound...].range(of: ">"),
           let he = lower.range(of: "</head", range: hsEnd.upperBound..<lower.endIndex) {
            head = String(doc[hsEnd.upperBound..<he.lowerBound])
        }
        var body: Substring
        if let bs = lower.range(of: "<body"), let bsEnd = lower[bs.upperBound...].range(of: ">") {
            let end = lower.range(of: "</body", range: bsEnd.upperBound..<lower.endIndex)?.lowerBound ?? lower.endIndex
            body = doc[bsEnd.upperBound..<end]
        } else {
            body = doc[...]
            // No <body>: strip the shell pieces that would otherwise render as text.
            if let he = lower.range(of: "</head>") { body = doc[he.upperBound...] }
            else if let hs = lower.range(of: "<html"), let hsEnd = lower[hs.upperBound...].range(of: ">") {
                body = doc[hsEnd.upperBound...]
            }
        }
        return (head, String(body))
    }

    /// Inline `<style>` blocks and `<link rel="stylesheet" href>` targets found in
    /// a head fragment (hrefs unresolved — the reader knows the base path).
    static func stylesheets(inHead head: String) -> (inline: [String], links: [String]) {
        var inline: [String] = []
        var links: [String] = []
        _ = scanTags(head) { tag in
            switch tag.name {
            case "style":
                if let inner = tag.rawInner { inline.append(inner) }
            case "link":
                let rel = (tag.attributes["rel"] ?? "").lowercased()
                let type = (tag.attributes["type"] ?? "").lowercased()
                if rel.contains("stylesheet") || type == "text/css", let href = tag.attributes["href"] {
                    links.append(href)
                }
            default: break
            }
            return nil
        }
        return (inline, links)
    }

    // MARK: Body sanitizing

    private static let droppedElements: Set<String> = [
        "script", "iframe", "object", "embed", "applet", "form", "input", "button",
        "select", "textarea", "meta", "link", "base", "title", "noscript",
    ]
    private static let resourceAttributes: Set<String> = ["src", "poster", "xlink:href", "srcset", "data"]

    /// Rewrites a chapter's body HTML for embedding: scripts / frames / forms
    /// go, `on*` attributes go, `id`s are chapter-prefixed, resources become data
    /// URIs and links become in-page anchors. Unknown tags pass through.
    static func sanitizeBody(_ body: String, context: Context) -> String {
        scanTags(body) { tag in
            if droppedElements.contains(tag.name) { return "" }
            if tag.name == "style" {
                // Chapter-level <style> inside the body: keep, resource-rewritten.
                guard let inner = tag.rawInner else { return "" }
                return "<style>\(rewriteCSS(inner, resolveResource: context.resolveResource))</style>"
            }
            if tag.isClosing { return nil }         // closing tags pass through untouched
            var attrs = tag.orderedAttributes
            var changed = false
            var i = 0
            while i < attrs.count {
                let key = attrs[i].name.lowercased()
                if key.hasPrefix("on") || key == "style" && attrs[i].value.lowercased().contains("javascript:") {
                    attrs.remove(at: i); changed = true; continue
                }
                let svgRef = tag.name == "image" || tag.name == "use"
                let isLink = (key == "href" || key == "xlink:href") && (tag.name == "a" || tag.name == "area")
                let isResource = resourceAttributes.contains(key) && !(key == "xlink:href" && !svgRef)
                    || (key == "href" && svgRef)
                if key == "id" || (key == "name" && tag.name == "a") {
                    attrs[i].value = prefixedID(chapter: context.chapterIndex, id: attrs[i].value)
                    changed = true
                } else if isLink {
                    if let target = context.resolveLink(attrs[i].value) {
                        attrs[i].value = target; changed = true
                    } else {
                        attrs.remove(at: i); changed = true; continue
                    }
                } else if isResource {
                    let value = attrs[i].value
                    if key == "srcset" { attrs.remove(at: i); changed = true; continue }
                    if value.hasPrefix("#") {                  // <use href="#symbol"> stays in-document
                        attrs[i].value = "#" + prefixedID(chapter: context.chapterIndex, id: String(value.dropFirst()))
                        changed = true
                    } else if value.hasPrefix("data:") {
                        // already inline
                    } else if let uri = context.resolveResource(value) {
                        attrs[i].value = uri; changed = true
                    } else if tag.name == "img" || tag.name == "image" {
                        return placeholder(for: value)
                    } else {
                        attrs.remove(at: i); changed = true; continue
                    }
                } else if key == "href" || key == "xlink:href" {
                    attrs.remove(at: i); changed = true; continue   // <link>/<base> are dropped anyway; be strict
                } else if key == "recindex" || key == "filepos" {
                    // MOBI7 leftovers already consumed by the resolver hooks
                    attrs.remove(at: i); changed = true; continue
                }
                i += 1
            }
            if !changed { return nil }
            return tag.rebuilt(with: attrs)
        }
    }

    /// Grey inline note for an image that could not be inlined (missing / over budget).
    static func placeholder(for ref: String) -> String {
        let name = (ref.removingPercentEncoding ?? ref).split(separator: "/").last.map(String.init) ?? ref
        return "<span class=\"ebook-missing\">[image: \(escape(name))]</span>"
    }

    // MARK: CSS

    /// Rewrites `url(...)` references in a stylesheet to data URIs (fonts, background
    /// images); `@import` rules are dropped (their targets are not reachable).
    static func rewriteCSS(_ css: String, resolveResource: (String) -> String?) -> String {
        var out = css
        if let imp = try? NSRegularExpression(pattern: "@import[^;]*;", options: [.caseInsensitive]) {
            out = imp.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        guard let re = try? NSRegularExpression(pattern: "url\\(\\s*(['\"]?)([^'\")]+)\\1\\s*\\)",
                                                options: [.caseInsensitive]) else { return out }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let ref = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if ref.hasPrefix("data:") {
                result += ns.substring(with: m.range)
            } else if let uri = resolveResource(ref) {
                result += "url(\"\(uri)\")"
            } else {
                result += "none"
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // MARK: Resources

    static func dataURI(_ data: Data, hint: String) -> String {
        "data:\(mimeType(for: data, hint: hint));base64,\(data.base64EncodedString())"
    }

    /// Magic-byte sniff first (ebook manifests lie about types surprisingly
    /// often), extension second.
    static func mimeType(for data: Data, hint: String) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 4 {
            if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
            if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
            if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
            if b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
            if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
               b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
            if b[0] == 0x77, b[1] == 0x4F, b[2] == 0x46, b[3] == 0x46 { return "font/woff" }
            if b[0] == 0x77, b[1] == 0x4F, b[2] == 0x46, b[3] == 0x32 { return "font/woff2" }
            if b[0] == 0x4F, b[1] == 0x54, b[2] == 0x54, b[3] == 0x4F { return "font/otf" }
            if b[0] == 0x00, b[1] == 0x01, b[2] == 0x00, b[3] == 0x00 { return "font/ttf" }
        }
        let ext = (hint as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        case "css": return "text/css"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        default:
            if let s = String(data: data.prefix(256), encoding: .utf8), s.contains("<svg") || s.contains("<?xml") {
                return "image/svg+xml"
            }
            return "application/octet-stream"
        }
    }

    // MARK: Page assembly

    /// The whole rendered page: fixed TOC sidebar (title / author / navigation),
    /// cover, then every chapter as a `<section id="ch-N">`. Book CSS is
    /// embedded verbatim; our chrome rules come last and are scoped, so a
    /// book's `div { … }` rule cannot restyle the sidebar. Always a light
    /// "paper" scheme: ebook stylesheets assume it.
    static func page(for book: EbookBook) -> String {
        var out = ""
        out.reserveCapacity(book.chapters.reduce(4096) { $0 + $1.html.utf8.count + 64 })
        out += "<!DOCTYPE html><html><head><meta charset=\"utf-8\">\n"
        out += "<title>\(escape(book.title))</title>\n"
        for css in book.css { out += "<style>\n\(css.replacingOccurrences(of: "</style", with: "<\\/style"))\n</style>\n" }
        out += "<style>\(chromeCSS)</style></head><body class=\"ebook-page\">\n"
        let hasTOC = !book.toc.isEmpty
        out += "<nav class=\"ebook-toc\"><div class=\"ebook-meta\">"
        out += "<div class=\"ebook-title\">\(escape(book.title))</div>"
        if let a = book.author, !a.isEmpty { out += "<div class=\"ebook-author\">\(escape(a))</div>" }
        out += "<div class=\"ebook-format\">\(escape(book.formatName)) · \(book.chapters.count)</div></div>"
        if hasTOC {
            out += "<ol class=\"ebook-nav\">"
            for e in book.toc {
                out += "<li class=\"d\(min(e.depth, 5))\"><a href=\"#\(e.anchor)\">\(escape(e.title))</a></li>"
            }
            out += "</ol>"
        }
        out += "</nav>\n<main class=\"ebook-main\">\n"
        if let cover = book.coverDataURI {
            out += "<section class=\"ebook-cover\"><img src=\"\(cover)\" alt=\"cover\"></section>\n"
        }
        for ch in book.chapters {
            out += "<section class=\"ebook-chapter\" id=\"\(ch.anchor)\">\n\(ch.html)\n</section>\n"
        }
        out += "</main></body></html>"
        return out
    }

    static func escape(_ s: String) -> String { MarkdownToHTML.escapeHTML(s) }

    private static let chromeCSS = """
    html { color-scheme: light; }
    body.ebook-page { margin: 0; background: #fbfaf7; color: #1b1b1b; \
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Helvetica Neue", serif; }
    nav.ebook-toc { position: fixed; left: 0; top: 0; bottom: 0; width: 260px; overflow-y: auto; \
    box-sizing: border-box; padding: 14px 12px; background: #f1efe9; border-right: 1px solid #d9d6cd; \
    font: 12.5px/1.45 -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; text-indent: 0; }
    nav.ebook-toc, nav.ebook-toc * { font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", sans-serif; \
    text-align: left; text-indent: 0; line-height: 1.45; color: #1b1b1b; }   /* immune to the book's div/p rules */
    nav.ebook-toc .ebook-meta { margin-bottom: 10px; padding-bottom: 8px; border-bottom: 1px solid #d9d6cd; }
    nav.ebook-toc .ebook-title { font-weight: 600; font-size: 14px; }
    nav.ebook-toc .ebook-author { color: #555; margin-top: 2px; }
    nav.ebook-toc .ebook-format { color: #888; font-size: 11px; margin-top: 4px; }
    nav.ebook-toc ol.ebook-nav { list-style: none; margin: 0; padding: 0; }
    nav.ebook-toc ol.ebook-nav li { margin: 0; padding: 2px 0; text-indent: 0; }
    nav.ebook-toc ol.ebook-nav li a { color: #1b1b1b; text-decoration: none; display: block; \
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    nav.ebook-toc ol.ebook-nav li a:hover { color: #0a5bd6; }
    nav.ebook-toc li.d1 a { padding-left: 12px; } nav.ebook-toc li.d2 a { padding-left: 24px; }
    nav.ebook-toc li.d3 a { padding-left: 36px; } nav.ebook-toc li.d4 a { padding-left: 48px; }
    nav.ebook-toc li.d5 a { padding-left: 60px; }
    main.ebook-main { margin-left: 260px; padding: 24px 40px 60px; max-width: 760px; }
    main.ebook-main section.ebook-chapter { margin-bottom: 3em; }
    main.ebook-main section.ebook-chapter + section.ebook-chapter { border-top: 1px dashed #cfcbc0; padding-top: 2em; }
    main.ebook-main section.ebook-cover { text-align: center; margin-bottom: 2em; }
    main.ebook-main section.ebook-cover img { max-height: 70vh; max-width: 100%; box-shadow: 0 2px 12px #0003; }
    main.ebook-main img, main.ebook-main svg, main.ebook-main image { max-width: 100%; height: auto; }
    main.ebook-main hr.ebook-pagebreak { border: none; border-top: 1px dashed #cfcbc0; margin: 2em 0; }
    .ebook-missing { display: inline-block; color: #777; background: #e8e6df; border-radius: 4px; \
    padding: 2px 8px; font-size: 0.85em; }
    @media (max-width: 700px) { nav.ebook-toc { display: none; } main.ebook-main { margin-left: 0; } }
    """

    // MARK: Tag scanner

    /// One tag as seen by the scanner.
    struct Tag {
        let name: String                      // lowercased, no "/" prefix
        let isClosing: Bool
        let raw: String                       // the full "<...>" text
        /// For `<script>`/`<style>` the scanner consumes up to the matching
        /// close tag; the inner text lands here (raw, not entity-decoded).
        let rawInner: String?
        var orderedAttributes: [Attribute]
        var attributes: [String: String] {
            var d: [String: String] = [:]
            for a in orderedAttributes where d[a.name.lowercased()] == nil { d[a.name.lowercased()] = a.value }
            return d
        }
        var selfClosing: Bool { raw.hasSuffix("/>") }

        func rebuilt(with attrs: [Attribute]) -> String {
            var s = "<\(name)"
            for a in attrs {
                let v = a.value.replacingOccurrences(of: "\"", with: "&quot;")
                s += " \(a.name)=\"\(v)\""
            }
            s += selfClosing ? "/>" : ">"
            return s
        }
    }

    struct Attribute { let name: String; var value: String }

    /// Walks every tag of `html` in order; `handler` returns a replacement for
    /// the tag (and, for script/style, its whole element) or nil to keep it.
    /// Comments, CDATA and processing instructions are dropped. Text between
    /// tags is copied verbatim. Byte-level scanning over UTF-8 — every
    /// delimiter is ASCII, so multi-byte characters are never split.
    static func scanTags(_ html: String, handler: (Tag) -> String?) -> String {
        let bytes = Array(html.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        let n = bytes.count
        var i = 0
        var textStart = 0
        func flushText(upTo end: Int) {
            if end > textStart { out.append(contentsOf: bytes[textStart..<end]) }
        }
        while i < n {
            guard bytes[i] == 0x3C /* < */ else { i += 1; continue }
            // Comment / CDATA / doctype / PI
            if i + 3 < n, bytes[i + 1] == 0x21 /* ! */ {
                if bytes[i + 2] == 0x2D, bytes[i + 3] == 0x2D {                // <!--
                    flushText(upTo: i)
                    i = find(bytes, [0x2D, 0x2D, 0x3E], from: i + 4).map { $0 + 3 } ?? n
                    textStart = i; continue
                }
                if i + 8 < n, bytes[i + 2] == 0x5B /* [ */ {                   // <![CDATA[
                    flushText(upTo: i)
                    i = find(bytes, [0x5D, 0x5D, 0x3E], from: i + 3).map { $0 + 3 } ?? n
                    textStart = i; continue
                }
                flushText(upTo: i)                                             // <!DOCTYPE …>
                i = find(bytes, [0x3E], from: i + 2).map { $0 + 1 } ?? n
                textStart = i; continue
            }
            if i + 1 < n, bytes[i + 1] == 0x3F /* ? */ {                        // <?xml …?>
                flushText(upTo: i)
                i = find(bytes, [0x3E], from: i + 2).map { $0 + 1 } ?? n
                textStart = i; continue
            }
            // A tag must start with a letter or "/"
            guard i + 1 < n, isNameStart(bytes[i + 1]) || bytes[i + 1] == 0x2F else { i += 1; continue }
            guard let close = tagEnd(bytes, from: i + 1) else { break }       // unterminated: rest is text
            let rawTag = String(decoding: bytes[i...close], as: UTF8.self)
            var tag = parseTag(rawTag)
            var elementEnd = close + 1
            if !tag.isClosing, tag.name == "script" || tag.name == "style", !tag.selfClosing {
                // Swallow to the matching close tag (case-insensitive search).
                let closeSeq = Array("</\(tag.name)".utf8)
                if let c = findCaseInsensitive(bytes, closeSeq, from: elementEnd),
                   let gt = find(bytes, [0x3E], from: c) {
                    tag = Tag(name: tag.name, isClosing: false, raw: tag.raw,
                              rawInner: String(decoding: bytes[elementEnd..<c], as: UTF8.self),
                              orderedAttributes: tag.orderedAttributes)
                    elementEnd = gt + 1
                } else {
                    tag = Tag(name: tag.name, isClosing: false, raw: tag.raw, rawInner: "",
                              orderedAttributes: tag.orderedAttributes)
                    elementEnd = n
                }
            }
            flushText(upTo: i)
            if let replacement = handler(tag) {
                out.append(contentsOf: replacement.utf8)
            } else {
                out.append(contentsOf: bytes[i..<elementEnd])
            }
            i = elementEnd
            textStart = i
        }
        flushText(upTo: n)
        return String(decoding: out, as: UTF8.self)
    }

    private static func isNameStart(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    /// Index of the `>` closing the tag that starts after `from`, honoring quotes.
    private static func tagEnd(_ b: [UInt8], from: Int) -> Int? {
        var i = from
        var quote: UInt8 = 0
        while i < b.count {
            let c = b[i]
            if quote != 0 {
                if c == quote { quote = 0 }
            } else if c == 0x22 || c == 0x27 {
                quote = c
            } else if c == 0x3E {
                return i
            } else if c == 0x3C {
                // A stray "<" before any ">" — malformed; treat the earlier "<" as text.
                return nil
            }
            i += 1
        }
        return nil
    }

    private static func find(_ b: [UInt8], _ pat: [UInt8], from: Int) -> Int? {
        guard !pat.isEmpty, b.count >= pat.count else { return nil }
        var i = max(0, from)
        let last = b.count - pat.count
        while i <= last {
            if b[i] == pat[0] {
                var ok = true
                for k in 1..<pat.count where b[i + k] != pat[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    private static func findCaseInsensitive(_ b: [UInt8], _ pat: [UInt8], from: Int) -> Int? {
        guard !pat.isEmpty, b.count >= pat.count else { return nil }
        let lowerPat = pat.map(lower)
        var i = max(0, from)
        let last = b.count - pat.count
        while i <= last {
            var ok = true
            for k in 0..<pat.count where lower(b[i + k]) != lowerPat[k] { ok = false; break }
            if ok { return i }
            i += 1
        }
        return nil
    }

    private static func lower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 32 : b }

    private static let attrRegex = try! NSRegularExpression(
        pattern: "([^\\s=\"'<>/]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+)))?")

    /// Parses `<name attr="v" …>` into a Tag. Tolerant of unquoted / valueless
    /// attributes; never throws.
    static func parseTag(_ raw: String) -> Tag {
        var inner = raw.dropFirst()              // "<"
        if inner.hasSuffix(">") { inner = inner.dropLast() }
        var isClosing = false
        if inner.hasPrefix("/") { isClosing = true; inner = inner.dropFirst() }
        if inner.hasSuffix("/") { inner = inner.dropLast() }
        let s = String(inner)
        // Name = up to first whitespace or "/"
        let nameEnd = s.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "/" }) ?? s.endIndex
        let name = String(s[..<nameEnd]).lowercased()
        var attrs: [Attribute] = []
        if !isClosing, nameEnd < s.endIndex {
            let rest = String(s[nameEnd...])
            let ns = rest as NSString
            for m in attrRegex.matches(in: rest, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1))
                var value = ""
                for g in 2...4 where m.range(at: g).location != NSNotFound {
                    value = ns.substring(with: m.range(at: g)); break
                }
                attrs.append(Attribute(name: key, value: decodeEntities(value)))
            }
        }
        return Tag(name: name, isClosing: isClosing, raw: raw, rawInner: nil, orderedAttributes: attrs)
    }

    /// Minimal entity decoding for attribute values (`&amp;` in hrefs is common).
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    // MARK: Path helpers (shared by readers)

    /// Resolves `ref` (percent-encoded, possibly with `../`) against the
    /// directory of `basePath`; both are archive-relative POSIX paths. The
    /// fragment is split off. Returns nil for absolute URLs.
    static func resolve(ref: String, relativeTo basePath: String) -> (path: String, fragment: String?)? {
        var r = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        var fragment: String?
        if let h = r.firstIndex(of: "#") {
            fragment = String(r[r.index(after: h)...])
            r = String(r[..<h])
        }
        if r.contains("://") || r.hasPrefix("mailto:") || r.hasPrefix("data:") { return nil }
        r = r.removingPercentEncoding ?? r
        if r.isEmpty { return (basePath, fragment) }
        let baseDir = (basePath as NSString).deletingLastPathComponent
        let joined = r.hasPrefix("/") ? String(r.dropFirst()) : (baseDir.isEmpty ? r : baseDir + "/" + r)
        return (normalizePath(joined), fragment)
    }

    static func normalizePath(_ p: String) -> String {
        var parts: [String] = []
        for c in p.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(c))
        }
        return parts.joined(separator: "/")
    }
}
