import Foundation

/// Kindle / Mobipocket reader: `.mobi` / `.prc` / `.azw` (MOBI7 = one HTML
/// stream, chapters cut at the NCX positions) and `.azw3` / KF8 (skeleton +
/// fragment tables rebuilt into per-file parts). Hybrid files (MOBI7 + KF8
/// behind a BOUNDARY record) use the KF8 half. DRM-encrypted books are
/// reported, never decrypted. Bare PalmDOC (`TEXtREAd`) renders as plain text.
enum MOBIReader {

    // MARK: Container

    struct Database {
        let bytes: [UInt8]
        let offsets: [Int]            // record start offsets + sentinel (file length)
        let type: String              // "BOOK" / "TEXt"
        let creator: String           // "MOBI" / "REAd"

        init(bytes: [UInt8]) throws {
            self.bytes = bytes
            guard bytes.count >= 78 + 8 else { throw EbookError.corrupt("too small for a PDB") }
            type = String(decoding: bytes[60..<64], as: UTF8.self)
            creator = String(decoding: bytes[64..<68], as: UTF8.self)
            let n = bytes.be16(76)
            guard n > 0, 78 + n * 8 <= bytes.count else { throw EbookError.corrupt("bad PDB record list") }
            var offs: [Int] = []
            for i in 0..<n { offs.append(bytes.be32(78 + i * 8)) }
            offs.append(bytes.count)
            // Offsets must be monotonic and inside the file.
            for i in 0..<n where offs[i] > offs[i + 1] || offs[i] > bytes.count {
                throw EbookError.corrupt("bad PDB record offsets")
            }
            offsets = offs
        }

        var recordCount: Int { offsets.count - 1 }

        func record(_ i: Int) -> [UInt8]? {
            guard i >= 0, i < recordCount else { return nil }
            return Array(bytes[offsets[i]..<offsets[i + 1]])
        }
    }

    /// PalmDOC + MOBI header fields we use (record-relative offsets per the
    /// MobileRead wiki). Index fields are stored ABSOLUTE (base already added).
    struct Header {
        let base: Int                 // record holding this header (0, or the KF8 boundary)
        let compression: Int
        let textLength: Int
        let textRecords: Int
        let recordSize: Int
        let encryption: Int
        let headerLength: Int
        let mobiVersion: Int
        let codepage: Int
        let fullName: String
        let firstImage: Int?
        let huffOffset: Int?
        let huffCount: Int
        let extraFlags: Int
        let ncxIndex: Int?
        let fdstIndex: Int?
        let fdstCount: Int
        let fragIndex: Int?
        let skelIndex: Int?
        let exth: [Int: [[UInt8]]]

        init(record r: [UInt8], base: Int) {
            self.base = base
            compression = r.be16(0)
            textLength = r.be32(4)
            textRecords = r.be16(8)
            recordSize = r.be16(10)
            encryption = r.be16(12)
            let isMobi = r.hasPrefix("MOBI", at: 16)
            let hlen = isMobi ? r.be32(20) : 0
            let version = isMobi ? r.be32(0x24) : 0
            let cp = isMobi ? r.be32(0x1C) : 65001
            headerLength = hlen
            mobiVersion = version
            codepage = cp
            // Index fields: 0 / 0xFFFFFFFF = absent; otherwise relative to `base`.
            let index: (Int) -> Int? = { off in
                guard isMobi, hlen + 16 > off else { return nil }
                let v = r.be32(off)
                return (v == 0xFFFF_FFFF || v == 0) ? nil : base + v
            }
            firstImage = index(0x6C)
            huffOffset = index(0x70)
            huffCount = isMobi ? r.be32(0x74) : 0
            extraFlags = (isMobi && hlen >= 0xE4 && version >= 5) ? r.be16(0xF2) : 0
            ncxIndex = index(0xF4)
            let kf8 = isMobi && version >= 8
            fdstIndex = kf8 ? index(0xC0) : nil
            fdstCount = kf8 ? r.be32(0xC4) : 0
            fragIndex = kf8 ? index(0xF8) : nil
            skelIndex = kf8 ? index(0xFC) : nil
            // Full name
            let nameOff = isMobi ? r.be32(0x54) : 0, nameLen = isMobi ? r.be32(0x58) : 0
            if isMobi, nameLen > 0, nameOff + nameLen <= r.count {
                fullName = MOBIReader.decode(r.slice(nameOff, nameOff + nameLen), codepage: cp)
            } else {
                fullName = ""
            }
            // EXTH
            var exth: [Int: [[UInt8]]] = [:]
            if isMobi, r.be32(0x80) & 0x40 != 0 {
                let start = 16 + hlen
                if r.slice(start, start + 4).hasPrefix("EXTH") {
                    let count = r.be32(start + 8)
                    var p = start + 12
                    for _ in 0..<min(count, 4096) {
                        let tag = r.be32(p), len = r.be32(p + 4)
                        guard len >= 8, p + len <= r.count else { break }
                        exth[tag, default: []].append(r.slice(p + 8, p + len))
                        p += len
                    }
                }
            }
            self.exth = exth
        }

        func exthString(_ tag: Int) -> String? {
            guard let d = exth[tag]?.first else { return nil }
            let s = MOBIReader.decode(d, codepage: codepage).trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        func exthInt(_ tag: Int) -> Int? {
            guard let d = exth[tag]?.first, d.count == 4 else { return nil }
            return d.be32(0)
        }
    }

    static func decode(_ bytes: [UInt8], codepage: Int) -> String {
        if codepage == 1252 {
            return String(bytes: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: Entry

    static func read(url: URL, isCancelled: () -> Bool = { false }) throws -> EbookBook {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw EbookError.corrupt("unreadable")
        }
        return try read(bytes: [UInt8](data), name: url.deletingPathExtension().lastPathComponent,
                        isCancelled: isCancelled)
    }

    static func read(bytes: [UInt8], name: String, isCancelled: () -> Bool = { false }) throws -> EbookBook {
        let db: Database
        do {
            db = try Database(bytes: bytes)
        } catch {
            if bytes.hasPrefix("CONT") { throw EbookError.unsupported("KFX") }   // Amazon's newer container
            throw error
        }
        guard db.type == "BOOK" && db.creator == "MOBI" || db.type == "TEXt" && db.creator == "REAd" else {
            if bytes.hasPrefix("CONT") { throw EbookError.unsupported("KFX") }
            throw EbookError.unsupported("not a Mobipocket database (\(db.type)\(db.creator))")
        }
        guard let rec0 = db.record(0) else { throw EbookError.corrupt("no record 0") }
        let h0 = Header(record: rec0, base: 0)
        if h0.encryption != 0 { throw EbookError.drm }

        // Hybrid MOBI7+KF8: EXTH 121 points at the KF8 header, right after a BOUNDARY record.
        var header = h0
        if h0.mobiVersion < 8, let b = h0.exthInt(121), b > 0, b < db.recordCount,
           let boundary = db.record(b - 1), boundary.hasPrefix("BOUNDARY"), let kf8rec = db.record(b) {
            let kh = Header(record: kf8rec, base: b)
            if kh.mobiVersion >= 8 { header = kh }
        }
        if header.encryption != 0 { throw EbookError.drm }

        let text = try decompressText(db: db, header: header, isCancelled: isCancelled)
        if isCancelled() { throw EbookError.cancelled }

        let title = header.exthString(503) ?? (header.fullName.isEmpty ? h0.fullName : header.fullName)
        var book = EbookBook(title: title.isEmpty ? name : title,
                             author: header.exthString(100),
                             formatName: header.mobiVersion >= 8 ? "KF8" : (header.headerLength > 0 ? "MOBI" : "PalmDOC"))
        let budget = EbookResourceBudget()
        let firstImage = h0.firstImage            // resource records are counted from the MOBI7 header
        func imageURI(_ n: Int) -> String? {      // n = 1-based resource number
            guard let fi = firstImage, n >= 1, let rec = db.record(fi + n - 1), rec.count > 4,
                  !rec.hasPrefix("FLIS"), !rec.hasPrefix("FCIS"), !rec.hasPrefix("FDST"),
                  !rec.hasPrefix("RESC"), !rec.hasPrefix("DATP"), !rec.hasPrefix("SRCS"),
                  !rec.hasPrefix("FONT"), !rec.hasPrefix("CONT"), !rec.hasPrefix("BOUNDARY"),
                  budget.take(rec.count) else { return nil }
            return EbookHTML.dataURI(Data(rec), hint: "")
        }
        if let off = header.exthInt(201) ?? h0.exthInt(201), let uri = imageURI(off + 1) { book.coverDataURI = uri }

        if header.headerLength == 0 {
            // Bare PalmDOC: plain text.
            let s = decode(text, codepage: 65001)
            book.chapters = [EbookChapter(index: 0, html: "<pre class=\"ebook-plain\">\(EbookHTML.escape(s))</pre>")]
            return book
        }
        if header.mobiVersion >= 8 {
            try buildKF8(db: db, header: header, text: text, imageURI: imageURI, into: &book, isCancelled: isCancelled)
        } else {
            try buildMOBI7(db: db, header: header, text: text, imageURI: imageURI, into: &book, isCancelled: isCancelled)
        }
        return book
    }

    // MARK: Text

    static func decompressText(db: Database, header h: Header, isCancelled: () -> Bool) throws -> [UInt8] {
        guard h.textRecords > 0, h.base + h.textRecords < db.recordCount else {
            throw EbookError.corrupt("text records out of range")
        }
        var huff: HuffCdic?
        if h.compression == MOBICompression.huffCdic.rawValue {
            guard let off = h.huffOffset, h.huffCount >= 2, let table = db.record(off) else {
                throw EbookError.corrupt("missing HUFF record")
            }
            var cdics: [[UInt8]] = []
            for i in 1..<h.huffCount { if let c = db.record(off + i) { cdics.append(c) } }
            guard let hc = HuffCdic(huff: table, cdics: cdics) else { throw EbookError.corrupt("bad HUFF/CDIC tables") }
            huff = hc
        } else if h.compression != MOBICompression.none.rawValue && h.compression != MOBICompression.palmDoc.rawValue {
            throw EbookError.unsupported("compression \(h.compression)")
        }
        var out: [UInt8] = []
        out.reserveCapacity(max(h.textLength, 0) + 4096)
        for i in 1...h.textRecords {
            if i % 64 == 0, isCancelled() { throw EbookError.cancelled }
            guard var rec = db.record(h.base + i) else { break }
            let trailing = MOBITrailing.size(of: rec, flags: h.extraFlags)
            rec.removeLast(trailing)
            switch h.compression {
            case MOBICompression.palmDoc.rawValue: out.append(contentsOf: PalmDoc.decompress(rec))
            case MOBICompression.huffCdic.rawValue:
                guard let d = huff?.unpack(rec) else { throw EbookError.corrupt("HUFF stream") }
                out.append(contentsOf: d)
            default: out.append(contentsOf: rec)
            }
        }
        return out
    }

    // MARK: KF8

    private static func buildKF8(db: Database, header h: Header, text: [UInt8], imageURI: @escaping (Int) -> String?,
                                 into book: inout EbookBook, isCancelled: () -> Bool) throws {
        // Flows (FDST): flow 0 = the HTML skeletons + fragments, others = CSS / SVG.
        var flows: [(Int, Int)] = []
        if let fi = h.fdstIndex, let rec = db.record(fi), rec.hasPrefix("FDST") {
            let n = rec.be32(8)
            for k in 0..<min(n, 4096) {
                let s = rec.be32(12 + k * 8), e = rec.be32(16 + k * 8)
                if s <= e, e <= text.count { flows.append((s, e)) }
            }
        }
        if flows.isEmpty { flows = [(0, text.count)] }
        func flow(_ i: Int) -> [UInt8]? {
            guard i >= 0, i < flows.count else { return nil }
            return text.slice(flows[i].0, flows[i].1)
        }
        let flow0 = flow(0) ?? text

        // Parts: skeleton i + its fragments (inserted at their positions).
        struct Part { let index: Int; var bytes: [UInt8] }
        var parts: [Part] = []
        var partOfFragment: [Int: Int] = [:]      // fragment row → part index
        if let si = h.skelIndex, let fi = h.fragIndex,
           let skel = MOBIIndex.read(headerIndex: si, record: db.record),
           let frag = MOBIIndex.read(headerIndex: fi, record: db.record), !skel.entries.isEmpty {
            var fp = 0
            for (i, s) in skel.entries.enumerated() {
                let fragCount = s.value(1) ?? 0
                let skelPos = s.value(6) ?? 0, skelLen = s.value(6, 1) ?? 0
                var base = skelPos + skelLen
                var skeleton = flow0.slice(skelPos, base)
                var added = 0                          // marker bytes inserted so far in this part
                for _ in 0..<fragCount {
                    guard fp < frag.entries.count else { break }
                    let f = frag.entries[fp]
                    let insertPos = Int(f.labelString) ?? skelPos
                    let length = f.value(6, 1) ?? 0
                    let slice = flow0.slice(base, base + length)
                    // Insert positions address the skeleton as grown by the previous
                    // fragments — our anchor markers are extra, so shift by them.
                    let at = max(0, min(skeleton.count, insertPos - skelPos + added))
                    // Anchor so kindle:pos:fid links and the NCX can target this fragment.
                    let marker = Array("<span id=\"kf\(fp)\"></span>".utf8)
                    skeleton.insert(contentsOf: marker + slice, at: at)
                    added += marker.count
                    base += length
                    partOfFragment[fp] = i
                    fp += 1
                }
                parts.append(Part(index: i, bytes: skeleton))
            }
        }
        if parts.isEmpty {
            // No usable skeleton/fragment tables: strip the per-file shells and
            // show the flow as one long chapter.
            let stripped = EbookHTML.scanTags(decode(flow0, codepage: h.codepage)) { tag in
                ["html", "head", "body", "meta", "title", "link"].contains(tag.name) ? "" : nil
            }
            parts = [Part(index: 0, bytes: Array(stripped.utf8))]
        }

        // Resolvers
        var flowURICache: [Int: String] = [:]
        var imageCache: [Int: String] = [:]
        let budgetImage: (Int) -> String? = { n in
            if let hit = imageCache[n] { return hit.isEmpty ? nil : hit }
            let uri = imageURI(n)
            imageCache[n] = uri ?? ""
            return uri
        }
        func resource(_ ref: String) -> String? {
            let r = ref.trimmingCharacters(in: .whitespaces)
            if r.hasPrefix("kindle:embed:") {
                guard let n = KindleBase32.decode(String(r.dropFirst(13).prefix { $0 != "?" })) else { return nil }
                return budgetImage(n)
            }
            if r.hasPrefix("kindle:flow:") {
                guard let n = KindleBase32.decode(String(r.dropFirst(12).prefix { $0 != "?" })) else { return nil }
                if let hit = flowURICache[n] { return hit.isEmpty ? nil : hit }
                guard let bytes = flow(n) else { flowURICache[n] = ""; return nil }
                let uri = EbookHTML.dataURI(Data(bytes), hint: r.contains("svg") ? "x.svg" : "")
                flowURICache[n] = uri
                return uri
            }
            return nil
        }
        func link(_ href: String) -> String? {
            let t = href.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return t }
            if lower.hasPrefix("kindle:pos:fid:") {
                let fidText = String(t.dropFirst(15).prefix { $0 != ":" })
                guard let fid = KindleBase32.decode(fidText), let part = partOfFragment[fid] else { return nil }
                return "#" + EbookHTML.prefixedID(chapter: part, id: "kf\(fid)")
            }
            if t.hasPrefix("#") { return nil }        // bare fragments never occur in KF8 output
            return nil
        }

        var cssSeen: Set<Int> = []
        var css: [String] = []
        for p in parts {
            if isCancelled() { throw EbookError.cancelled }
            let doc = decode(p.bytes, codepage: h.codepage)
            let split = EbookHTML.splitDocument(doc)
            let styles = EbookHTML.stylesheets(inHead: split.head)
            for href in styles.links where href.hasPrefix("kindle:flow:") {
                if let n = KindleBase32.decode(String(href.dropFirst(12).prefix { $0 != "?" })),
                   cssSeen.insert(n).inserted, let bytes = flow(n) {
                    css.append(EbookHTML.rewriteCSS(decode(bytes, codepage: h.codepage), resolveResource: resource))
                }
            }
            for s in styles.inline { css.append(EbookHTML.rewriteCSS(s, resolveResource: resource)) }
            let ctx = EbookHTML.Context(chapterIndex: p.index, resolveResource: resource, resolveLink: link)
            book.chapters.append(EbookChapter(index: p.index, html: EbookHTML.sanitizeBody(split.body, context: ctx)))
        }
        book.css = css

        // NCX → sidebar. Tag 6 = (fragment row, offset), tag 3 = label, tag 4 = depth.
        if let ni = h.ncxIndex, let ncx = MOBIIndex.read(headerIndex: ni, record: db.record) {
            for e in ncx.entries {
                guard let label = ncx.cncxString(e.value(3)), !label.isEmpty else { continue }
                let depth = e.value(4) ?? 0
                if let fid = e.value(6), let part = partOfFragment[fid] {
                    book.toc.append(EbookTOCEntry(title: label, depth: depth,
                                                  anchor: EbookHTML.prefixedID(chapter: part, id: "kf\(fid)")))
                } else if let pos = e.value(1), let part = partContaining(position: pos, parts: parts.map { $0.bytes.count }) {
                    book.toc.append(EbookTOCEntry(title: label, depth: depth, anchor: EbookHTML.chapterAnchor(part)))
                }
            }
        }
    }

    /// Fallback mapping of a flow-0 text offset to the part whose reconstructed
    /// bytes cover it (approximate: parts grow by the inserted anchors).
    private static func partContaining(position: Int, parts lengths: [Int]) -> Int? {
        var acc = 0
        for (i, len) in lengths.enumerated() {
            acc += len
            if position < acc { return i }
        }
        return lengths.isEmpty ? nil : lengths.count - 1
    }

    // MARK: MOBI7

    private static func buildMOBI7(db: Database, header h: Header, text: [UInt8], imageURI: @escaping (Int) -> String?,
                                   into book: inout EbookBook, isCancelled: () -> Bool) throws {
        // Body byte range inside the single HTML stream; positions (filepos,
        // NCX) are offsets into the WHOLE stream, so chapters are cut in bytes.
        let lower = text.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 + 32 : $0 }
        var bodyStart = 0, bodyEnd = text.count
        if let bs = find(lower, Array("<body".utf8), from: 0), let gt = find(lower, [0x3E], from: bs) {
            bodyStart = gt + 1
            if let be = find(lower, Array("</body".utf8), from: bodyStart) { bodyEnd = be }
        }
        guard bodyStart <= bodyEnd else { throw EbookError.corrupt("body range") }

        // Navigation points
        struct Nav { let pos: Int; let label: String; let depth: Int }
        var navs: [Nav] = []
        if let ni = h.ncxIndex, let ncx = MOBIIndex.read(headerIndex: ni, record: db.record) {
            for e in ncx.entries {
                guard let pos = e.value(1), let label = ncx.cncxString(e.value(3)), !label.isEmpty else { continue }
                navs.append(Nav(pos: pos, label: label, depth: e.value(4) ?? 0))
            }
        }
        // Every filepos target gets an anchor; chapters are cut at NCX positions
        // (or at page breaks when there is no NCX).
        var targets: Set<Int> = Set(navs.map { $0.pos })
        var p = bodyStart
        let fileposKey = Array("filepos=".utf8)
        while let f = find(lower, fileposKey, from: p) {
            var q = f + fileposKey.count
            if q < text.count, text[q] == 0x22 || text[q] == 0x27 { q += 1 }
            var v = 0, digits = 0
            while q < text.count, text[q] >= 0x30, text[q] <= 0x39, digits < 12 { v = v * 10 + Int(text[q] - 0x30); q += 1; digits += 1 }
            if digits > 0 { targets.insert(v) }
            p = q
        }
        var cuts: [Int] = navs.map { $0.pos }.filter { $0 > bodyStart && $0 < bodyEnd }
        if cuts.isEmpty {
            var q = bodyStart
            let pb = Array("<mbp:pagebreak".utf8)
            while let f = find(lower, pb, from: q) { cuts.append(f); q = f + pb.count }
        }
        cuts = Array(Set(cuts.map { snapToTag(text, $0, floor: bodyStart) })).sorted()
        var bounds = [bodyStart] + cuts.filter { $0 > bodyStart } + [bodyEnd]
        bounds = Array(Set(bounds)).sorted()
        let ranges: [(Int, Int)] = (0..<(bounds.count - 1)).map { (bounds[$0], bounds[$0 + 1]) }
        func chapter(containing pos: Int) -> Int? {
            guard pos >= bodyStart, pos < bodyEnd else { return pos < bodyStart ? 0 : ranges.count - 1 }
            var lo = 0, hi = ranges.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if ranges[mid].0 <= pos { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
        let anchorPositions = targets.map { snapToTag(text, $0, floor: bodyStart) }.filter { $0 >= bodyStart && $0 <= bodyEnd }.sorted()
        var anchorByTarget: [Int: Int] = [:]              // original filepos → snapped
        for t in targets { anchorByTarget[t] = snapToTag(text, t, floor: bodyStart) }

        var imageCache: [Int: String] = [:]
        func resource(_ ref: String) -> String? {
            guard ref.hasPrefix("mobi:rec:"), let n = Int(ref.dropFirst(9)) else { return nil }
            if let hit = imageCache[n] { return hit.isEmpty ? nil : hit }
            let uri = imageURI(n)
            imageCache[n] = uri ?? ""
            return uri
        }
        func link(_ href: String) -> String? {
            let t = href.trimmingCharacters(in: .whitespaces)
            let lower = t.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return t }
            if t.hasPrefix("#fp"), let pos = Int(t.dropFirst(3)), let snapped = anchorByTarget[pos],
               let ch = chapter(containing: snapped) {
                return "#" + EbookHTML.prefixedID(chapter: ch, id: "fp\(snapped)")
            }
            return nil
        }

        var ai = 0
        for (i, r) in ranges.enumerated() {
            if isCancelled() { throw EbookError.cancelled }
            // Emit the range with anchors injected at every target inside it.
            var chunk: [UInt8] = []
            chunk.reserveCapacity(r.1 - r.0 + 64)
            var cursor = r.0
            while ai < anchorPositions.count, anchorPositions[ai] < r.1 {
                let a = anchorPositions[ai]
                if a >= cursor {
                    chunk.append(contentsOf: text[cursor..<a])
                    chunk.append(contentsOf: Array("<a id=\"fp\(a)\"></a>".utf8))
                    cursor = a
                }
                ai += 1
            }
            chunk.append(contentsOf: text[cursor..<r.1])
            var html = decode(chunk, codepage: h.codepage)
            html = rewriteMobi7Markup(html)
            let ctx = EbookHTML.Context(chapterIndex: i, resolveResource: resource, resolveLink: link)
            book.chapters.append(EbookChapter(index: i, html: EbookHTML.sanitizeBody(html, context: ctx)))
        }
        for n in navs {
            let snapped = anchorByTarget[n.pos] ?? n.pos
            guard let ch = chapter(containing: snapped) else { continue }
            book.toc.append(EbookTOCEntry(title: n.label, depth: n.depth,
                                          anchor: EbookHTML.prefixedID(chapter: ch, id: "fp\(snapped)")))
        }
    }

    /// `recindex` → `src="mobi:rec:N"`, `filepos` → `href="#fpN"`, `<mbp:pagebreak>`
    /// → a styled rule. Plain string rewriting ahead of the tag scanner.
    static func rewriteMobi7Markup(_ html: String) -> String {
        var s = html
        let rules: [(String, String)] = [
            ("(?i)\\brecindex\\s*=\\s*[\"']?0*(\\d+)[\"']?", "src=\"mobi:rec:$1\""),
            ("(?i)\\bfilepos\\s*=\\s*[\"']?0*(\\d+)[\"']?", "href=\"#fp$1\""),
            ("(?i)<mbp:pagebreak\\s*/?>", "<hr class=\"ebook-pagebreak\">"),
            ("(?i)</?mbp:[a-z]+\\s*/?>", ""),
        ]
        for (pattern, template) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    /// filepos values point at a tag start; when one lands mid-text (rare), back
    /// up to the nearest `<` within a short window so the chapter cut never
    /// splits a tag.
    private static func snapToTag(_ text: [UInt8], _ pos: Int, floor: Int) -> Int {
        guard pos < text.count else { return text.count }
        if text[pos] == 0x3C { return pos }
        var k = pos - 1
        while k >= floor, k >= pos - 96 {
            if text[k] == 0x3C { return k }
            if text[k] == 0x3E { break }             // walked past the previous tag's end: pos is text
            k -= 1
        }
        return pos
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
}

extension Array where Element == UInt8 {
    func hasPrefix(_ magic: String, at offset: Int) -> Bool {
        let m = Array(magic.utf8)
        guard offset >= 0, offset + m.count <= count else { return false }
        return Array(self[offset..<offset + m.count]) == m
    }
}
