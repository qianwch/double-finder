import Foundation

// MARK: - Tiny XML tree (XMLParser-backed)

/// Minimal DOM for the small XML documents an EPUB carries (container.xml,
/// the OPF package, NCX, the EPUB3 nav document). Element names are compared
/// without namespace prefixes.
final class XMLNode {
    let name: String                        // local name, lowercased
    let attributes: [String: String]        // keys lowercased, prefixes stripped
    var children: [XMLNode] = []
    var text = ""
    weak var parent: XMLNode?

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func first(_ name: String) -> XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [XMLNode] { children.filter { $0.name == name } }

    /// Depth-first search for the first element with this local name.
    func find(_ name: String) -> XMLNode? {
        if self.name == name { return self }
        for c in children { if let f = c.find(name) { return f } }
        return nil
    }

    /// All text below this node, whitespace-collapsed.
    var deepText: String {
        var s = text
        for c in children { s += c.deepText }
        return s
    }
    var collapsedText: String {
        deepText.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

final class XMLTree: NSObject, XMLParserDelegate {
    private var root: XMLNode?
    private var current: XMLNode?

    /// Parses `data`; `html` mode first swaps the HTML named entities XML does
    /// not know (`&nbsp;` …) for numeric references, since XMLParser would
    /// otherwise abort on the first one.
    static func parse(_ data: Data, html: Bool = false) -> XMLNode? {
        var d = data
        if html, var s = String(data: data, encoding: .utf8) {
            for (name, code) in htmlEntities { s = s.replacingOccurrences(of: "&\(name);", with: "&#\(code);") }
            d = Data(s.utf8)
        }
        let tree = XMLTree()
        let parser = XMLParser(data: d)
        parser.delegate = tree
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        _ = parser.parse()
        return tree.root
    }

    private static let htmlEntities: [(String, Int)] = [
        ("nbsp", 160), ("copy", 169), ("reg", 174), ("mdash", 8212), ("ndash", 8211), ("hellip", 8230),
        ("lsquo", 8216), ("rsquo", 8217), ("ldquo", 8220), ("rdquo", 8221), ("laquo", 171), ("raquo", 187),
        ("trade", 8482), ("shy", 173), ("bull", 8226), ("middot", 183), ("deg", 176), ("times", 215),
        ("ensp", 8194), ("emsp", 8195), ("thinsp", 8201), ("zwnj", 8204), ("zwj", 8205),
    ]

    private static func local(_ qname: String) -> String {
        (qname.split(separator: ":").last.map(String.init) ?? qname).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attrs: [String: String] = [:]
        for (k, v) in attributeDict { attrs[Self.local(k)] = v }
        let node = XMLNode(name: Self.local(elementName), attributes: attrs)
        node.parent = current
        if let c = current { c.children.append(node) } else { root = node }
        current = node
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        current = current?.parent
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current?.text += string
    }
}

// MARK: - EPUB

/// EPUB 2/3 reader: the zip is extracted with libarchive into a scratch folder,
/// the OPF package gives spine order + manifest, the nav document (EPUB3) or
/// NCX (EPUB2) gives the table of contents. Every spine item is sanitized into
/// one chapter; images / fonts / stylesheets are inlined.
enum EPUBReader {

    static func read(url: URL, isCancelled: () -> Bool = { false }) throws -> EbookBook {
        let scratch = NSTemporaryDirectory() + "DoubleFinder-Ebook-" + ProcessInfo.processInfo.globallyUniqueString
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        do {
            try LibArchive.extractAll(archivePath: url.path, to: scratch, password: nil)
        } catch is ArchiveEncryptedError {
            throw EbookError.drm
        } catch {
            throw EbookError.corrupt("not a zip container: \(error.localizedDescription)")
        }
        if isCancelled() { throw EbookError.cancelled }
        return try build(root: scratch, isCancelled: isCancelled)
    }

    /// Builds the book from an already-unpacked EPUB tree (also the unit-test entry).
    static func build(root: String, isCancelled: () -> Bool = { false }) throws -> EbookBook {
        let fs = FileManager.default
        func bytes(_ rel: String) -> Data? {
            fs.contents(atPath: (root as NSString).appendingPathComponent(rel))
        }
        // Adobe/LCP DRM leaves an encryption manifest; treat any as unreadable
        // (font obfuscation is the harmless exception — fonts are optional).
        if let enc = bytes("META-INF/encryption.xml"), let tree = XMLTree.parse(enc) {
            let encrypted = collect(tree, named: "encrypteddata")
            let nonFont = encrypted.contains { node in
                let uri = node.find("cipherreference")?.attributes["uri"]?.lowercased() ?? ""
                return !(uri.hasSuffix(".ttf") || uri.hasSuffix(".otf") || uri.hasSuffix(".woff") || uri.hasSuffix(".woff2"))
            }
            if nonFont { throw EbookError.drm }
        }
        guard let containerData = bytes("META-INF/container.xml"),
              let container = XMLTree.parse(containerData),
              let opfPath = collect(container, named: "rootfile").first?.attributes["full-path"],
              let opfData = bytes(opfPath), let opf = XMLTree.parse(opfData)
        else { throw EbookError.corrupt("missing container.xml / OPF package") }

        // Manifest: id → (href path, media type, properties)
        struct Item { let path: String; let type: String; let properties: String }
        var manifest: [String: Item] = [:]
        var pathToID: [String: String] = [:]
        for item in opf.find("manifest")?.all("item") ?? [] {
            guard let id = item.attributes["id"], let href = item.attributes["href"],
                  let r = EbookHTML.resolve(ref: href, relativeTo: opfPath) else { continue }
            let it = Item(path: r.path, type: (item.attributes["media-type"] ?? "").lowercased(),
                          properties: item.attributes["properties"] ?? "")
            manifest[id] = it
            pathToID[r.path] = id
        }
        let spineNode = opf.find("spine")
        var spinePaths: [String] = []
        for ref in spineNode?.all("itemref") ?? [] {
            guard let id = ref.attributes["idref"], let it = manifest[id] else { continue }
            if it.type.contains("html") || it.type.contains("xml") || it.type.isEmpty { spinePaths.append(it.path) }
        }
        guard !spinePaths.isEmpty else { throw EbookError.corrupt("empty spine") }
        var chapterIndexByPath: [String: Int] = [:]
        for (i, p) in spinePaths.enumerated() { chapterIndexByPath[p] = i }

        // Metadata
        let meta = opf.find("metadata")
        let title = meta?.first("title")?.collapsedText ?? ""
        let author = meta?.first("creator")?.collapsedText
        var book = EbookBook(title: title.isEmpty ? (root as NSString).lastPathComponent : title,
                             author: author, formatName: "EPUB")

        // Resources
        let budget = EbookResourceBudget()
        var uriCache: [String: String] = [:]
        func resource(_ ref: String, from basePath: String) -> String? {
            guard let r = EbookHTML.resolve(ref: ref, relativeTo: basePath) else { return nil }
            if let hit = uriCache[r.path] { return hit.isEmpty ? nil : hit }
            guard let data = bytes(r.path), budget.take(data.count) else { uriCache[r.path] = ""; return nil }
            let uri = EbookHTML.dataURI(data, hint: r.path)
            uriCache[r.path] = uri
            return uri
        }

        // Cover: EPUB3 property, then EPUB2 <meta name="cover">
        var coverPath: String?
        if let it = manifest.values.first(where: { $0.properties.split(separator: " ").contains("cover-image") }) {
            coverPath = it.path
        } else if let coverID = meta?.all("meta").first(where: { $0.attributes["name"]?.lowercased() == "cover" })?
                    .attributes["content"], let it = manifest[coverID] {
            coverPath = it.path
        }
        if let cp = coverPath, let data = bytes(cp), budget.take(data.count) {
            book.coverDataURI = EbookHTML.dataURI(data, hint: cp)
        }

        // Chapters
        var cssSeen: Set<String> = []
        var cssTexts: [String] = []
        func addCSS(_ text: String, basePath: String) {
            let rewritten = EbookHTML.rewriteCSS(text) { resource($0, from: basePath) }
            let key = String(rewritten.prefix(4096)) + "#\(rewritten.utf8.count)"
            if cssSeen.insert(key).inserted { cssTexts.append(rewritten) }
        }
        for (i, path) in spinePaths.enumerated() {
            if isCancelled() { throw EbookError.cancelled }
            guard let data = bytes(path) else {
                book.chapters.append(EbookChapter(index: i, html: EbookHTML.placeholder(for: path))); continue
            }
            let doc = String(decoding: data, as: UTF8.self)
            let parts = EbookHTML.splitDocument(doc)
            let styles = EbookHTML.stylesheets(inHead: parts.head)
            for href in styles.links {
                if let r = EbookHTML.resolve(ref: href, relativeTo: path), let css = bytes(r.path) {
                    addCSS(String(decoding: css, as: UTF8.self), basePath: r.path)
                }
            }
            for s in styles.inline { addCSS(s, basePath: path) }
            let ctx = EbookHTML.Context(
                chapterIndex: i,
                resolveResource: { resource($0, from: path) },
                resolveLink: { href in
                    let t = href.trimmingCharacters(in: .whitespaces)
                    if t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") { return t }
                    guard let r = EbookHTML.resolve(ref: t, relativeTo: path) else { return nil }
                    guard let target = chapterIndexByPath[r.path] else { return nil }
                    if let f = r.fragment, !f.isEmpty { return "#" + EbookHTML.prefixedID(chapter: target, id: f) }
                    return "#" + EbookHTML.chapterAnchor(target)
                })
            book.chapters.append(EbookChapter(index: i, html: EbookHTML.sanitizeBody(parts.body, context: ctx)))
        }
        book.css = cssTexts

        // Table of contents: EPUB3 nav first, NCX second.
        func anchor(for href: String, from basePath: String) -> String? {
            guard let r = EbookHTML.resolve(ref: href, relativeTo: basePath),
                  let idx = chapterIndexByPath[r.path] else { return nil }
            if let f = r.fragment, !f.isEmpty { return "#" + EbookHTML.prefixedID(chapter: idx, id: f) }
            return "#" + EbookHTML.chapterAnchor(idx)
        }
        var toc: [EbookTOCEntry] = []
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let data = bytes(nav.path), let tree = XMLTree.parse(data, html: true) {
            let tocNav = collect(tree, named: "nav").first { ($0.attributes["type"] ?? "").lowercased().contains("toc") }
                ?? collect(tree, named: "nav").first
            if let list = tocNav?.first("ol") { walkNavList(list, depth: 0, basePath: nav.path, anchor: anchor, into: &toc) }
        }
        if toc.isEmpty {
            var ncxPath: String?
            if let tocID = spineNode?.attributes["toc"], let it = manifest[tocID] { ncxPath = it.path }
            else if let it = manifest.values.first(where: { $0.type == "application/x-dtbncx+xml" }) { ncxPath = it.path }
            if let p = ncxPath, let data = bytes(p), let tree = XMLTree.parse(data), let map = tree.find("navmap") {
                walkNavPoints(map, depth: 0, basePath: p, anchor: anchor, into: &toc)
            }
        }
        // Anchors are dropped from entries by the walkers when unresolvable; strip
        // entries whose anchor is empty so the sidebar never shows dead links.
        book.toc = toc.filter { !$0.anchor.isEmpty }
        return book
    }

    private static func walkNavList(_ ol: XMLNode, depth: Int, basePath: String,
                                    anchor: (String, String) -> String?, into toc: inout [EbookTOCEntry]) {
        guard depth < 32 else { return }
        for li in ol.all("li") {
            if let a = li.first("a") {
                let title = a.collapsedText
                if !title.isEmpty, let href = a.attributes["href"], let target = anchor(href, basePath) {
                    toc.append(EbookTOCEntry(title: title, depth: depth, anchor: String(target.dropFirst())))
                }
            } else if let span = li.first("span") {
                let title = span.collapsedText
                if !title.isEmpty { toc.append(EbookTOCEntry(title: title, depth: depth, anchor: "")) }
            }
            for sub in li.all("ol") { walkNavList(sub, depth: depth + 1, basePath: basePath, anchor: anchor, into: &toc) }
        }
    }

    private static func walkNavPoints(_ node: XMLNode, depth: Int, basePath: String,
                                      anchor: (String, String) -> String?, into toc: inout [EbookTOCEntry]) {
        guard depth < 32 else { return }
        for np in node.all("navpoint") {
            let title = np.first("navlabel")?.collapsedText ?? ""
            if !title.isEmpty, let src = np.first("content")?.attributes["src"], let target = anchor(src, basePath) {
                toc.append(EbookTOCEntry(title: title, depth: depth, anchor: String(target.dropFirst())))
            }
            walkNavPoints(np, depth: depth + 1, basePath: basePath, anchor: anchor, into: &toc)
        }
    }

    private static func collect(_ node: XMLNode, named name: String) -> [XMLNode] {
        var out: [XMLNode] = []
        if node.name == name { out.append(node) }
        for c in node.children { out += collect(c, named: name) }
        return out
    }
}
