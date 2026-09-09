import Foundation

/// Self-contained markdown → HTML converter (design §4.2). CommonMark common
/// subset + GFM tables/task lists. Raw HTML is always escaped (viewers open
/// untrusted files). Never fails — worst case everything renders as escaped
/// paragraphs. Local images inline as base64 data URIs (§4.2, Task 4).
///
/// Performance shape (matters: the Lister renders md up to tens of MB): the
/// block scanner works on `Substring` lines sliced from the ORIGINAL string
/// (no per-line String copies, no Foundation `trimmingCharacters`), and the
/// inline parser scans raw UTF-8 bytes. Every markdown delimiter is ASCII and
/// UTF-8 continuation bytes are ≥ 0x80, so byte comparison is exact and every
/// slice boundary the scanner produces is a valid scalar boundary. Output is
/// escaped in a single byte pass. Character-level (grapheme) scanning was ~5×
/// slower; do not reintroduce `Array(text)`.
enum MarkdownToHTML {

    /// Back-compat single-value entry (existing tests and callers that don't
    /// care about diagrams).
    static func render(_ markdown: String, baseDir: URL?) -> String {
        renderDocument(markdown, baseDir: baseDir).html
    }

    /// Primary entry (design §4): the html contains a placeholder
    /// `<div class="diagram" data-idx="N">` (escaped source code inside) per
    /// diagram fence; `diagrams` lists them in data-idx order for async
    /// rendering + substituteDiagrams. `isCancelled` is polled every few
    /// hundred lines: a caller rendering off the main thread can abandon a
    /// huge document early (the partial output is garbage, discard it).
    static func renderDocument(_ markdown: String, baseDir: URL?,
                               isCancelled: () -> Bool = { false }) -> (html: String, diagrams: [DiagramBlock]) {
        var diagrams: [DiagramBlock] = []
        // One byte buffer end-to-end: every block/inline emitter appends to it
        // (no intermediate Strings), decoded to a String exactly once.
        var out: [UInt8] = []
        out.reserveCapacity(markdown.utf8.count * 2 + css.utf8.count + 256)
        out.add("<!DOCTYPE html><html><head><meta charset=\"utf-8\">\n<style>\(css)</style></head><body>")
        blocks(splitLines(markdown), baseDir: baseDir, diagrams: &diagrams, isCancelled: isCancelled, into: &out)
        out.add("</body></html>")
        return (String(decoding: out, as: UTF8.self), diagrams)
    }

    /// Splits on LF, CRLF and lone CR in one pass (replacing the old
    /// normalize-then-components approach, which copied the whole document
    /// twice). Line breaks are never part of a line, so `---\r` style
    /// mis-detections cannot happen. A trailing terminator yields a final
    /// empty line, exactly like `components(separatedBy: "\n")` did.
    static func splitLines(_ s: String) -> [Substring] {
        var lines: [Substring] = []
        let u = s.utf8
        var start = u.startIndex
        var i = u.startIndex
        while i < u.endIndex {
            let b = u[i]
            if b == 0x0A || b == 0x0D {
                lines.append(s[start..<i])
                var next = u.index(after: i)
                if b == 0x0D, next < u.endIndex, u[next] == 0x0A { next = u.index(after: next) }
                start = next; i = next
            } else {
                i = u.index(after: i)
            }
        }
        lines.append(s[start..<u.endIndex])
        return lines
    }

    // MARK: whitespace helpers (pure Swift — Foundation's trimmingCharacters
    // bridges through NSString and dominated block-level scanning)

    @inline(__always) private static func isSpaceByte(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

    /// Same set as `CharacterSet.whitespaces`: space, tab and Unicode Zs
    /// (U+00A0, U+3000 …). Only consulted for a non-ASCII edge character.
    private static func isTrimmable(_ c: Character) -> Bool {
        if c == " " || c == "\t" { return true }
        guard let s = c.unicodeScalars.first, s.value >= 0x80 else { return false }
        return s.properties.generalCategory == .spaceSeparator
    }

    /// Trims leading/trailing whitespace. ASCII fast path on the UTF-8 view;
    /// a non-ASCII byte at either end takes the Character-level slow path so
    /// full-width / no-break spaces still trim like they did with Foundation.
    static func trim(_ s: Substring) -> Substring {
        let u = s.utf8
        var lo = u.startIndex, hi = u.endIndex
        while lo < hi, isSpaceByte(u[lo]) { lo = u.index(after: lo) }
        while hi > lo, isSpaceByte(u[u.index(before: hi)]) { hi = u.index(before: hi) }
        var r = s[lo..<hi]
        if let f = r.utf8.first, f >= 0x80, let c = r.first, isTrimmable(c) { r = trimSlow(r) }
        else if let l = r.utf8.last, l >= 0x80, let c = r.last, isTrimmable(c) { r = trimSlow(r) }
        return r
    }

    private static func trimSlow(_ s: Substring) -> Substring {
        var r = s.drop(while: isTrimmable)
        while let c = r.last, isTrimmable(c) { r = r.dropLast() }
        return r
    }


    /// Byte-wise `hasPrefix` for Substrings. `StringProtocol.hasPrefix` on a
    /// Substring compares Characters (grapheme breaking per call) — measured
    /// as the dominant block-scanner cost. Every prefix we test is ASCII.
    @inline(__always) private static func starts(_ s: Substring, with p: StaticString) -> Bool {
        let u = s.utf8
        guard u.count >= p.utf8CodeUnitCount else { return false }
        return p.withUTF8Buffer { pb in
            var idx = u.startIndex
            for byte in pb {
                if u[idx] != byte { return false }
                idx = u.index(after: idx)
            }
            return true
        }
    }

    /// Splits on `|` by byte (Substring.split(separator:) is Character-based).
    private static func splitPipes(_ s: Substring, omittingEmpty: Bool) -> [Substring] {
        var parts: [Substring] = []
        let u = s.utf8
        var start = u.startIndex
        var i = start
        while i < u.endIndex {
            if u[i] == 0x7C {
                let piece = s[start..<i]
                if !omittingEmpty || !piece.isEmpty { parts.append(piece) }
                start = u.index(after: i)
            }
            i = u.index(after: i)
        }
        let piece = s[start..<u.endIndex]
        if !omittingEmpty || !piece.isEmpty { parts.append(piece) }
        return parts
    }

    // MARK: block-level state machine

    /// Blockquote nesting recurses one level per leading `>`; a hostile file of
    /// thousands of `> > > …` prefixes would otherwise blow the stack (observed
    /// segfault at ~5000 levels) with quadratic cost. Past this depth, `>` lines
    /// degrade to escaped paragraph text — ugly but safe ("Never fails").
    private static let maxQuoteDepth = 64

    private static func blocks(_ lines: [Substring], baseDir: URL?, depth: Int = 0,
                               diagrams: inout [DiagramBlock], isCancelled: () -> Bool,
                               into out: inout [UInt8]) {
        var i = 0
        var paragraph: [Substring] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.add("<p>")
            for (n, p) in paragraph.enumerated() {
                if n > 0 { out.append(0x0A) }
                inline(p, baseDir: baseDir, into: &out)
            }
            out.add("</p>\n")
            paragraph = []
        }
        while i < lines.count {
            if i & 511 == 0, isCancelled() { return }
            let line = lines[i]
            let trimmed = trim(line)
            // fenced code block (highest priority)
            if starts(trimmed, with: "```") {
                flushParagraph()
                let lang = String(trim(trimmed.dropFirst(3)))
                var code: [Substring] = []
                i += 1
                while i < lines.count, !trim(lines[i]).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1   // skip closing fence (or EOF — unterminated runs to end)
                let joined = code.joined(separator: "\n")
                if let kind = DiagramKind(fenceLanguage: lang) {
                    // Diagram fence → placeholder (still a readable code block until
                    // the async SVG lands via substituteDiagrams, design §5).
                    out.add("<div class=\"diagram\" data-idx=\"\(diagrams.count)\"><pre><code>")
                    appendEscaped(joined, into: &out)
                    out.add("</code></pre></div>\n")
                    diagrams.append(DiagramBlock(kind: kind, source: joined))
                } else {
                    codeBlock(joined, language: lang, into: &out)
                }
                continue
            }
            // heading
            if let h = headingLevel(trimmed) {
                flushParagraph()
                let text = trim(trimmed.dropFirst(h))
                out.add("<h\(h)>"); inline(text, baseDir: baseDir, into: &out); out.add("</h\(h)>\n")
                i += 1; continue
            }
            // horizontal rule
            if isHR(trimmed) { flushParagraph(); out.add("<hr>\n"); i += 1; continue }
            // blockquote: gather consecutive > lines, strip one level, recurse
            // (depth-capped; over the cap the > lines fall through to a paragraph)
            if starts(trimmed, with: ">"), depth < maxQuoteDepth {
                flushParagraph()
                var quoted: [Substring] = []
                while i < lines.count {
                    let t = trim(lines[i])
                    guard starts(t, with: ">") else { break }
                    quoted.append(t.dropFirst(starts(t, with: "> ") ? 2 : 1))
                    i += 1
                }
                out.add("<blockquote>")
                blocks(quoted, baseDir: baseDir, depth: depth + 1, diagrams: &diagrams, isCancelled: isCancelled, into: &out)
                out.add("</blockquote>\n")
                continue
            }
            // list (ordered/unordered/task, indent-nested) — collect the whole
            // list block and hand it to listBlock. Continuation detection matches
            // listMarker's indent rule: two spaces or one tab both count.
            if listMarker(line) != nil {
                flushParagraph()
                var block: [Substring] = []
                while i < lines.count, listMarker(lines[i]) != nil || (isListContinuation(lines[i]) && !trim(lines[i]).isEmpty) {
                    block.append(lines[i]); i += 1
                }
                listBlock(block, baseDir: baseDir, into: &out)
                continue
            }
            // GFM table：当前行含 | 且下一行是分隔行
            if line.utf8.contains(0x7C), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                var rows: [Substring] = [line, lines[i + 1]]
                i += 2
                while i < lines.count, lines[i].utf8.contains(0x7C) { rows.append(lines[i]); i += 1 }
                tableBlock(rows, baseDir: baseDir, into: &out)
                continue
            }
            // blank → paragraph break
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
    }

    // MARK: helpers

    /// "#".."######" heading level, or nil. Requires at least one space (or
    /// end of line) after the hashes so "#tag" in a paragraph doesn't match.
    private static func headingLevel(_ trimmed: Substring) -> Int? {
        let u = trimmed.utf8
        var count = 0
        var idx = u.startIndex
        while idx < u.endIndex, u[idx] == 0x23 { count += 1; idx = u.index(after: idx) }
        guard count >= 1, count <= 6 else { return nil }
        guard idx == u.endIndex || u[idx] == 0x20 else { return nil }
        return count
    }

    /// `---`, `***`, `___` (>= 3 identical chars, optionally space-separated).
    private static func isHR(_ trimmed: Substring) -> Bool {
        var first: UInt8 = 0
        var count = 0
        for b in trimmed.utf8 {
            if b == 0x20 { continue }
            if count == 0 {
                guard b == 0x2D || b == 0x2A || b == 0x5F else { return false }   // - * _
                first = b
            } else if b != first {
                return false
            }
            count += 1
        }
        return count >= 3
    }

    /// Detects a list-item marker on a raw (un-indent-stripped) line: `- `,
    /// `* `, `+ ` (unordered) or `N. ` / `N) ` (ordered). Returns the indent
    /// (leading whitespace width, tab = 1 level worth of columns handled by
    /// caller) and whether it's ordered — used by `listBlock`.
    private struct ListMarkerInfo { let indent: Int; let ordered: Bool; let rest: Substring }

    /// A non-marker line continues the current list item when it is indented —
    /// two spaces or one tab, mirroring `listMarker`'s indent counting.
    private static func isListContinuation(_ line: Substring) -> Bool {
        starts(line, with: "  ") || starts(line, with: "\t")
    }

    private static func listMarker(_ line: Substring) -> ListMarkerInfo? {
        let u = line.utf8
        var indent = 0
        var idx = u.startIndex
        while idx < u.endIndex {
            let b = u[idx]
            if b == 0x20 { indent += 1 } else if b == 0x09 { indent += 2 } else { break }
            idx = u.index(after: idx)
        }
        let rest = line[idx...]
        let ru = rest.utf8
        guard let m = ru.first else { return nil }
        if m == 0x2D || m == 0x2A || m == 0x2B {                       // - * +
            let second = ru.index(after: ru.startIndex)
            if second < ru.endIndex, ru[second] == 0x20 {
                return ListMarkerInfo(indent: indent, ordered: false, rest: rest[ru.index(after: second)...])
            }
            return nil
        }
        // ordered: ASCII digits then "." or ")" then space
        var digits = 0
        var i = ru.startIndex
        while i < ru.endIndex, ru[i] >= 0x30, ru[i] <= 0x39 { digits += 1; i = ru.index(after: i) }
        if digits > 0, i < ru.endIndex, (ru[i] == 0x2E || ru[i] == 0x29) {
            let after = ru.index(after: i)
            if after < ru.endIndex, ru[after] == 0x20 {
                return ListMarkerInfo(indent: indent, ordered: true, rest: rest[ru.index(after: after)...])
            }
        }
        return nil
    }

    /// Builds nested `<ul>`/`<ol>` from a flat run of list-item lines using an
    /// indent stack: 2 spaces (or 1 tab) = one nesting level. Continuation
    /// lines indented under an item but without their own marker are appended
    /// to that item's text (lazy continuation).
    private static func listBlock(_ lines: [Substring], baseDir: URL?, into out: inout [UInt8]) {
        struct Level { let indent: Int; let ordered: Bool; var openedLI: Bool }
        var stack: [Level] = []
        var i = 0

        func openList(indent: Int, ordered: Bool) {
            stack.append(Level(indent: indent, ordered: ordered, openedLI: false))
            out.add(ordered ? "<ol>" : "<ul>")
        }
        func closeTopLI() {
            if let top = stack.last, top.openedLI {
                out.add("</li>")
                stack[stack.count - 1].openedLI = false
            }
        }

        while i < lines.count {
            let line = lines[i]
            guard let marker = listMarker(line) else {
                // Continuation line (indented, no marker) — append as plain text
                // to the currently open item, if any.
                if let top = stack.last, top.openedLI {
                    out.append(0x0A); inline(trim(line), baseDir: baseDir, into: &out)
                }
                i += 1; continue
            }
            // Pop only levels strictly deeper than this marker's indent; a
            // same-indent type change (ul↔ol) is handled by the `else if` below.
            while let top = stack.last, marker.indent < top.indent {
                closeTopLI()
                let level = stack.removeLast()
                out.add(level.ordered ? "</ol>" : "</ul>")
            }
            if stack.isEmpty || marker.indent > stack.last!.indent {
                // New nested level. If the parent item is open, nest the new
                // list INSIDE that <li> (before its closing tag) — do not close it.
                openList(indent: marker.indent, ordered: marker.ordered)
            } else if stack.last!.ordered != marker.ordered {
                // Same indent but different list type: close and reopen.
                closeTopLI()
                let level = stack.removeLast()
                out.add(level.ordered ? "</ol>" : "</ul>")
                openList(indent: marker.indent, ordered: marker.ordered)
            } else {
                // Same level, next item.
                closeTopLI()
            }

            var text = marker.rest
            var checkbox = ""
            if starts(text, with: "[ ] ") {
                checkbox = "<input type=\"checkbox\" disabled>"
                text = text.dropFirst(4)
            } else if starts(text, with: "[x] ") || starts(text, with: "[X] ") {
                checkbox = "<input type=\"checkbox\" disabled checked>"
                text = text.dropFirst(4)
            }
            out.add("<li>"); out.add(checkbox); inline(text, baseDir: baseDir, into: &out)
            stack[stack.count - 1].openedLI = true
            i += 1
        }
        while !stack.isEmpty {
            closeTopLI()
            let level = stack.removeLast()
            out.add(level.ordered ? "</ol>" : "</ul>")
        }
        out.append(0x0A)
    }

    /// GFM table separator row: `---|---` / `:--|--:` etc.
    private static func isTableSeparator(_ line: Substring) -> Bool {
        let t = trim(line)
        guard t.utf8.contains(0x2D) else { return false }
        let cells = splitPipes(t, omittingEmpty: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = trim(cell)
            guard !c.isEmpty else { return false }
            return c.utf8.allSatisfy { $0 == 0x2D || $0 == 0x3A }   // - :
        }
    }

    /// Splits a table row on `|`, dropping one optional leading/trailing
    /// empty cell produced by a leading/trailing pipe (`| a | b |` → ["a",
    /// "b"], not ["", "a", "b", ""]).
    private static func tableCells(_ row: Substring) -> [Substring] {
        var cells = splitPipes(row, omittingEmpty: false).map(trim)
        if let first = cells.first, first.isEmpty { cells.removeFirst() }
        if let last = cells.last, last.isEmpty { cells.removeLast() }
        return cells
    }

    /// GFM table: `rows[0]` is the header, `rows[1]` the alignment row
    /// (`:--` left / `--:` right / `:-:` center / plain `-` no alignment),
    /// the rest are data rows. Cell content is inline-parsed.
    private static func tableBlock(_ rows: [Substring], baseDir: URL?, into out: inout [UInt8]) {
        guard rows.count >= 2 else { return }
        let headerCells = tableCells(rows[0])
        let aligns: [String?] = tableCells(rows[1]).map { spec in
            let left = starts(spec, with: ":")
            let right = spec.utf8.last == 0x3A
            if left, right { return "center" }
            if left { return "left" }
            if right { return "right" }
            return nil
        }
        func alignAttr(_ index: Int) -> String {
            guard index < aligns.count, let a = aligns[index] else { return "" }
            return " style=\"text-align:\(a)\""
        }
        out.add("<table>\n<thead><tr>")
        for (idx, cell) in headerCells.enumerated() {
            out.add("<th\(alignAttr(idx))>"); inline(cell, baseDir: baseDir, into: &out); out.add("</th>")
        }
        out.add("</tr></thead>\n<tbody>\n")
        for row in rows.dropFirst(2) {
            out.add("<tr>")
            for (idx, cell) in tableCells(row).enumerated() {
                out.add("<td\(alignAttr(idx))>"); inline(cell, baseDir: baseDir, into: &out); out.add("</td>")
            }
            out.add("</tr>\n")
        }
        out.add("</tbody>\n</table>\n")
    }

    /// Post-pass result per diagram index (design §4). `failureNote` text must
    /// arrive ALREADY tr()-translated — this stays a pure function.
    enum DiagramSubstitute { case svg(String); case failureNote(String) }

    /// Replaces each `<div class="diagram" data-idx="N">…</div>` placeholder:
    /// `.svg` swaps the whole block for the rendered SVG (plantuml gets a white
    /// card class — its SVGs assume a light background); `.failureNote` keeps
    /// the code block and prepends an italic note. Missing indices stay as-is.
    /// Placeholder innards are escaped HTML (can never contain a nested
    /// `</div>`), so scanning to the next `</div>` is exact. Placeholders come
    /// in document order, so the search resumes from the end of the previous
    /// substitution — single sweep, and a pathological SVG containing a literal
    /// later placeholder tag can never be matched (it sits behind the cursor).
    static func substituteDiagrams(_ html: String, diagrams: [DiagramBlock],
                                   results: [Int: DiagramSubstitute]) -> String {
        var out = html
        var cursor = out.startIndex
        for (idx, block) in diagrams.enumerated() {
            guard let result = results[idx] else { continue }
            let open = "<div class=\"diagram\" data-idx=\"\(idx)\">"
            guard let openRange = out.range(of: open, range: cursor..<out.endIndex),
                  let closeRange = out.range(of: "</div>", range: openRange.upperBound..<out.endIndex)
            else { continue }
            switch result {
            case .svg(let svg):
                let kindClass = block.kind == .plantuml ? " diagram-plantuml" : ""
                let replacement = "<div class=\"diagram rendered\(kindClass)\">\(svg)</div>"
                // Mutation invalidates indices — carry the cursor over as an offset.
                let start = out.distance(from: out.startIndex, to: openRange.lowerBound)
                out.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: replacement)
                cursor = out.index(out.startIndex, offsetBy: start + replacement.count)
            case .failureNote(let note):
                let insertion = "<div class=\"diagram-note\">\(escapeHTML(note))</div>"
                let start = out.distance(from: out.startIndex, to: openRange.upperBound)
                out.insert(contentsOf: insertion, at: openRange.upperBound)
                cursor = out.index(out.startIndex, offsetBy: start + insertion.count)
            }
        }
        return out
    }

    /// Fenced code：语言可识别 → SyntaxHighlighter token 着色 <span class="kw|str|com|num">
    private static func codeBlock(_ code: String, language: String, into out: inout [UInt8]) {
        out.add("<pre><code>")
        if let spec = LanguageSpec.language(forExtension: language) {
            highlightedHTML(code, spec: spec, into: &out)   // 逐 token 切片、每片转义、token 片包 span
        } else {
            appendEscaped(code, into: &out)
        }
        out.add("</code></pre>\n")
    }

    /// Slices `code` by `SyntaxHighlighter` token ranges into alternating
    /// plain/colored segments (tokens are position-ordered, non-overlapping),
    /// escaping every segment and wrapping colored ones in a `<span>`. Token
    /// ranges are UTF-16 (the highlighter also feeds NSTextStorage); they are
    /// walked into UTF-8 offsets in one forward pass over the byte buffer —
    /// no NSString substrings, no per-token String allocations.
    private static func highlightedHTML(_ code: String, spec: LanguageSpec, into out: inout [UInt8]) {
        let tokens = SyntaxHighlighter.tokenize(code, spec: spec)
        var code = code
        code.withUTF8 { b in
            var u8 = 0, u16 = 0
            // Advance to UTF-16 offset `target`, consuming whole scalars so u8
            // always sits on a scalar boundary (4-byte scalars = 2 code units).
            func advance(to target: Int) {
                while u16 < target, u8 < b.count {
                    let len = scalarLength(b[u8])
                    u16 += len == 4 ? 2 : 1
                    u8 += len
                }
                if u8 > b.count { u8 = b.count }   // truncated trailing scalar
            }
            var cursor = 0
            for token in tokens {
                guard token.range.location >= cursor else { continue }   // defensive: skip overlap
                let plainStart = u8
                advance(to: token.range.location)
                appendEscaped(b, from: plainStart, to: u8, into: &out)
                let tokenStart = u8
                advance(to: NSMaxRange(token.range))
                out.add("<span class=\"\(cssClass(for: token.kind))\">")
                appendEscaped(b, from: tokenStart, to: u8, into: &out)
                out.add("</span>")
                cursor = NSMaxRange(token.range)
            }
            appendEscaped(b, from: u8, to: b.count, into: &out)
        }
    }

    /// Fixed kind → CSS class mapping (design-fixed, do not change).
    private static func cssClass(for kind: TokenKind) -> String {
        switch kind {
        case .keyword: return "kw"
        case .string: return "str"
        case .comment: return "com"
        case .number: return "num"
        }
    }

    // MARK: inline parser (UTF-8 byte scanner)

    /// Inline parser (design §4.2). Order: backslash escape → inline code →
    /// image → link → strong (**/__) → em (*/_) → del (~~). Content inside
    /// strong/em/link text is parsed recursively; inline code is not.
    static func inline(_ text: String, baseDir: URL?) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count + 32)
        inline(Substring(text), baseDir: baseDir, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Streams the parsed inline HTML into `out`, scanning the text's UTF-8
    /// storage in place (`withUTF8` only copies for a bridged NSString).
    static func inline(_ text: Substring, baseDir: URL?, into out: inout [UInt8]) {
        var text = text
        text.withUTF8 { b in
            inlineBytes(b, from: 0, to: b.count, baseDir: baseDir, into: &out)
        }
    }

    /// Core scanner over `b[lo..<hi]`, appending HTML bytes to `out`. Nested
    /// content (emphasis / link labels) recurses on a sub-range of the same
    /// buffer — no copies. All delimiters are ASCII; multibyte scalars only
    /// ever appear inside plain runs (or after a backslash, handled below).
    private static func inlineBytes(_ b: UnsafeBufferPointer<UInt8>, from lo: Int, to hi: Int,
                                    baseDir: URL?, into out: inout [UInt8]) {
        var i = lo
        // Start of the current run of markup-free bytes, or nil when no run is
        // open. Runs are escaped in one batch at flush.
        var runStart: Int? = nil
        func flushPlain() {
            guard let start = runStart else { return }
            appendEscaped(b, from: start, to: i, into: &out)
            runStart = nil
        }
        func find(_ m0: UInt8, _ m1: UInt8?, from: Int) -> Int? {
            var j = from
            let last = m1 == nil ? hi - 1 : hi - 2
            while j <= last {
                if b[j] == m0, m1 == nil || b[j + 1] == m1! { return j }
                j += 1
            }
            return nil
        }
        // Tries to match a delimiter run (e.g. "**", "__", "~~", "*", "_") at
        // position `i`. On success, appends the wrapped, recursively-parsed
        // inner HTML to `out`, advances `i` past the closing delimiter and
        // returns true. On failure (no closer, or empty content) returns
        // false and leaves `out`/`i` untouched so the caller can try the
        // next marker.
        func matchDelimited(_ m0: UInt8, _ m1: UInt8?, tag: StaticString) -> Bool {
            let mlen = m1 == nil ? 1 : 2
            guard i + mlen <= hi, b[i] == m0, m1 == nil || b[i + 1] == m1! else { return false }
            guard var close = find(m0, m1, from: i + mlen), close > i + mlen else { return false }
            // Align the closing delimiter to the END of its run of identical
            // characters, so "**bold *and em***" closes the outer "**" on the
            // last two "*" of the trailing "***" run — leaving "bold *and em*"
            // as the inner content, whose single "*" pair recurses into <em>.
            while close + mlen < hi, b[close + mlen] == m0 { close += 1 }
            flushPlain()
            out.append(0x3C); out.add(tag); out.append(0x3E)                     // <tag>
            inlineBytes(b, from: i + mlen, to: close, baseDir: baseDir, into: &out)
            out.append(0x3C); out.append(0x2F); out.add(tag); out.append(0x3E)   // </tag>
            i = close + mlen
            return true
        }

        while i < hi {
            let c = b[i]
            switch c {
            case 0x5C:   // backslash escape: \ + punctuation/symbol → literal character.
                // Flush the run up to the backslash, then resume the run AT the
                // escaped character (skipping only the backslash itself) so it
                // still gets batch-escaped with whatever plain text follows.
                if i + 1 < hi, isPunctuationOrSymbol(b, at: i + 1, end: hi) {
                    flushPlain()
                    runStart = i + 1
                    i += 1 + scalarLength(b[i + 1]); continue
                }
            case 0x60:   // ` inline code — content is NOT parsed further.
                if let close = find(0x60, nil, from: i + 1) {
                    flushPlain()
                    out.add("<code>")
                    appendEscaped(b, from: i + 1, to: close, into: &out)
                    out.add("</code>")
                    i = close + 1; continue
                }
            case 0x21:   // ![alt](src)
                if i + 1 < hi, b[i + 1] == 0x5B, let pair = bracketPair(b, from: i + 1, end: hi) {
                    flushPlain()
                    out.add(imageHTML(alt: String(decoding: UnsafeBufferPointer(rebasing: b[pair.label]), as: UTF8.self),
                                      src: String(decoding: UnsafeBufferPointer(rebasing: b[pair.url]), as: UTF8.self),
                                      baseDir: baseDir))
                    i = pair.next; continue
                }
            case 0x5B:   // [label](url)
                if let pair = bracketPair(b, from: i, end: hi) {
                    flushPlain()
                    out.add("<a href=\"")
                    appendEscaped(b, from: pair.url.lowerBound, to: pair.url.upperBound, into: &out)
                    out.add("\">")
                    inlineBytes(b, from: pair.label.lowerBound, to: pair.label.upperBound, baseDir: baseDir, into: &out)
                    out.add("</a>")
                    i = pair.next; continue
                }
            // Strong / del must be checked before single-char em, since "**"
            // begins with a byte that also has a single-char meaning ("*");
            // "__" likewise must precede "_". Dispatching on the byte keeps
            // ordinary text clear of all delimiter machinery.
            case 0x2A:   // *
                if matchDelimited(0x2A, 0x2A, tag: "strong") { continue }
                if matchDelimited(0x2A, nil, tag: "em") { continue }
            case 0x5F:   // _
                if matchDelimited(0x5F, 0x5F, tag: "strong") { continue }
                if matchDelimited(0x5F, nil, tag: "em") { continue }
            case 0x7E:   // ~
                if matchDelimited(0x7E, 0x7E, tag: "del") { continue }
            default:
                break
            }
            if runStart == nil { runStart = i }
            i += 1
        }
        flushPlain()
    }

    /// Byte length of the UTF-8 scalar starting with `lead` (1 for ASCII and,
    /// defensively, for a stray continuation byte).
    @inline(__always) private static func scalarLength(_ lead: UInt8) -> Int {
        if lead < 0x80 { return 1 }
        if lead >= 0xF0 { return 4 }
        if lead >= 0xE0 { return 3 }
        if lead >= 0xC0 { return 2 }
        return 1
    }

    /// `Character.isPunctuation || Character.isSymbol` for the scalar at `at`.
    /// ASCII: every printable non-alphanumeric is one or the other. Non-ASCII
    /// (rare after a backslash): decode the scalar and ask Unicode.
    private static func isPunctuationOrSymbol(_ b: UnsafeBufferPointer<UInt8>, at: Int, end: Int) -> Bool {
        let c = b[at]
        if c < 0x80 {
            return (c >= 0x21 && c <= 0x2F) || (c >= 0x3A && c <= 0x40)
                || (c >= 0x5B && c <= 0x60) || (c >= 0x7B && c <= 0x7E)
        }
        let len = scalarLength(c)
        guard at + len <= end,
              let scalar = String(decoding: UnsafeBufferPointer(rebasing: b[at..<(at + len)]), as: UTF8.self).unicodeScalars.first
        else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// Scan caps for `bracketPair`. Without them a flood of `[` characters
    /// makes every position run a failing O(n) scan — quadratic overall
    /// (measured: 50K `[` took 41s; a 2MB file extrapolates to hours, on the
    /// main thread). 999 is the CommonMark link-label limit; 4096 is a
    /// generous URL bound. Both count UTF-8 bytes (not characters) since the
    /// scanner is byte-based. Past the cap the pattern fails fast and the `[`
    /// renders literally — flood inputs are linear again.
    private static let maxLinkLabelLength = 999
    private static let maxLinkURLLength = 4096

    /// Parses `[label](url)` starting at `from` (which must point at the
    /// opening `[`). No nested brackets/parens are supported inside label or
    /// url (accepted degradation). Returns the label and url byte ranges plus
    /// the index just past the closing `)`, or nil if the pattern doesn't match.
    private static func bracketPair(_ b: UnsafeBufferPointer<UInt8>, from: Int, end: Int)
        -> (label: Range<Int>, url: Range<Int>, next: Int)? {
        guard from < end, b[from] == 0x5B else { return nil }
        var j = from + 1
        let labelStart = j
        // The scan window is bounded up front so the cap costs one min().
        var limit = min(end, labelStart + maxLinkLabelLength + 1)
        while j < limit, b[j] != 0x5D { j += 1 }
        guard j < end, b[j] == 0x5D, j - labelStart <= maxLinkLabelLength else { return nil }
        let label = labelStart..<j
        j += 1
        guard j < end, b[j] == 0x28 else { return nil }
        j += 1
        let urlStart = j
        limit = min(end, urlStart + maxLinkURLLength + 1)
        while j < limit, b[j] != 0x29 { j += 1 }
        guard j < end, b[j] == 0x29, j - urlStart <= maxLinkURLLength else { return nil }
        let url = urlStart..<j
        j += 1
        return (label, url, j)
    }

    /// Renders `![alt](src)`. Remote (http/https) sources pass through as a
    /// plain `<img>` tag. Local/relative sources are resolved against
    /// `baseDir` and inlined as a base64 data URI (so the rendered HTML has
    /// no external file dependencies); on any failure — nil baseDir, path
    /// escaping outside baseDir, unreadable file, oversized file, or
    /// unresolvable path — a `.img-missing` placeholder span is emitted
    /// instead of a broken `<img>` tag.
    private static let maxImageBytes = 8 * 1024 * 1024

    private static func imageHTML(alt: String, src: String, baseDir: URL?) -> String {
        let altEscaped = escapeHTML(alt)
        if src.hasPrefix("http://") || src.hasPrefix("https://") {
            return "<img src=\"\(escapeHTML(src))\" alt=\"\(altEscaped)\">"
        }
        let fileName = (src as NSString).lastPathComponent
        guard let baseDir else {
            return "<span class=\"img-missing\">[image: \(escapeHTML(fileName))]</span>"
        }
        // standardizedFileURL only folds "../" textually; resolvingSymlinksInPath
        // additionally resolves symlinks, so a link INSIDE baseDir pointing
        // OUTSIDE cannot smuggle external files past the containment check.
        // Both sides are resolved so /var ↔ /private/var stay consistent.
        let resolved = baseDir.appendingPathComponent(src).standardizedFileURL.resolvingSymlinksInPath()
        let baseStandardized = baseDir.standardizedFileURL.resolvingSymlinksInPath()
        // Trailing slash is mandatory: without it, "/a/b" would prefix-match
        // the sibling directory "/a/b-evil", letting a crafted relative path
        // escape baseDir undetected.
        guard resolved.path.hasPrefix(baseStandardized.path + "/") else {
            return "<span class=\"img-missing\">[image: \(escapeHTML(fileName))]</span>"
        }
        // Regular files only: a FIFO named pic.png would make Data(contentsOf:)
        // block the main thread forever.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size <= maxImageBytes,
              let data = try? Data(contentsOf: resolved) else {
            return "<span class=\"img-missing\">[image: \(escapeHTML(fileName))]</span>"
        }
        let ext = resolved.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "svg": mime = "image/svg+xml"
        case "webp": mime = "image/webp"
        default: mime = "application/octet-stream"
        }
        let base64 = data.base64EncodedString()
        return "<img src=\"data:\(mime);base64,\(base64)\" alt=\"\(altEscaped)\">"
    }

    // MARK: escaping

    /// Single-pass HTML escape of `b[lo..<hi]` appended to `out`. Only the
    /// four bytes that matter (`& < > "`) are rewritten; everything else,
    /// multibyte scalars included, is copied through untouched.
    private static func appendEscaped(_ b: UnsafeBufferPointer<UInt8>, from lo: Int, to hi: Int, into out: inout [UInt8]) {
        var runStart = lo
        var i = lo
        while i < hi {
            let entity: StaticString
            switch b[i] {
            case 0x26: entity = "&amp;"
            case 0x3C: entity = "&lt;"
            case 0x3E: entity = "&gt;"
            case 0x22: entity = "&quot;"
            default: i += 1; continue
            }
            if runStart < i { out.append(contentsOf: UnsafeBufferPointer(rebasing: b[runStart..<i])) }
            out.add(entity)
            i += 1
            runStart = i
        }
        if runStart < hi { out.append(contentsOf: UnsafeBufferPointer(rebasing: b[runStart..<hi])) }
    }

    private static func appendEscaped(_ s: String, into out: inout [UInt8]) {
        var s = s
        s.withUTF8 { appendEscaped($0, from: 0, to: $0.count, into: &out) }
    }

    static func escapeHTML(_ s: String) -> String {
        // Fast reject: most fragments (alt texts, notes) contain nothing to
        // escape — skip the copy entirely.
        guard s.utf8.contains(where: { $0 == 0x26 || $0 == 0x3C || $0 == 0x3E || $0 == 0x22 }) else { return s }
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count + 16)
        appendEscaped(s, into: &out)
        return String(decoding: out, as: UTF8.self)
    }

    /// Embedded CSS: light/dark via `prefers-color-scheme`, monospace code,
    /// bordered tables, readable max-width. Must never contain the literal
    /// "<span class=" substring (unknown-lang code fences render as plain
    /// escaped text with no spans; a test asserts that).
    private static let css = """
    body { max-width: 860px; margin: 0 auto; padding: 1.5em; \
    font: 15px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
    pre, code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }
    pre { padding: 0.8em 1em; border-radius: 6px; overflow-x: auto; }
    blockquote { margin: 0 0 1em; padding: 0.2em 1em; border-left: 4px solid #8888; }
    table { border-collapse: collapse; margin-bottom: 1em; }
    th, td { border: 1px solid #8888; padding: 0.3em 0.6em; }
    hr { border: none; border-top: 1px solid #8888; margin: 1.5em 0; }
    .kw { color: #cf51b7; font-weight: 600; }
    .str { color: #d2412c; }
    .com { color: #6b7280; font-style: italic; } /* gray = conventional HTML comment color; text mode uses systemGreen, intentional divergence */
    .num { color: #1c6fd6; }
    @media (prefers-color-scheme: light) {
      body { background: #ffffff; color: #1b1b1b; }
      pre { background: #f5f5f5; }
    }
    @media (prefers-color-scheme: dark) {
      body { background: #1e1e1e; color: #e4e4e4; }
      pre { background: #2a2a2a; }
    }
    .diagram { margin: 1em 0; }
    .diagram.rendered { text-align: center; }
    .diagram.rendered svg { max-width: 100%; height: auto; }
    .diagram-plantuml.rendered { background: #ffffff; border-radius: 6px; padding: 8px; display: inline-block; }
    .diagram-note { font-style: italic; color: #6b7280; font-size: 0.85em; margin-bottom: 0.3em; }
    """
}

/// Output-buffer sugar for the converter: HTML is assembled as UTF-8 bytes and
/// decoded to a String once at the end.
private extension Array where Element == UInt8 {
    @inline(__always) mutating func add(_ s: String) { append(contentsOf: s.utf8) }
    @inline(__always) mutating func add(_ s: StaticString) { s.withUTF8Buffer { append(contentsOf: $0) } }
}
