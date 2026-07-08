import Foundation

/// Self-contained markdown → HTML converter (design §4.2). CommonMark common
/// subset + GFM tables/task lists. Raw HTML is always escaped (viewers open
/// untrusted files). Never fails — worst case everything renders as escaped
/// paragraphs. Local images inline as base64 data URIs (§4.2, Task 4).
enum MarkdownToHTML {

    static func render(_ markdown: String, baseDir: URL?) -> String {
        // Normalize CRLF and lone CR to LF first: lines are split on "\n" only,
        // and a trailing \r would break hr detection ("---\r"), fence language
        // lookup ("swift\r") and table-separator detection.
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let bodyHTML = blocks(normalized.components(separatedBy: "\n"), baseDir: baseDir)
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>\(css)</style></head><body>\(bodyHTML)</body></html>
        """
    }

    // MARK: block-level state machine

    /// Blockquote nesting recurses one level per leading `>`; a hostile file of
    /// thousands of `> > > …` prefixes would otherwise blow the stack (observed
    /// segfault at ~5000 levels) with quadratic cost. Past this depth, `>` lines
    /// degrade to escaped paragraph text — ugly but safe ("Never fails").
    private static let maxQuoteDepth = 64

    private static func blocks(_ lines: [String], baseDir: URL?, depth: Int = 0) -> String {
        var out = ""
        var i = 0
        var paragraph: [String] = []
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out += "<p>" + paragraph.map { inline($0, baseDir: baseDir) }.joined(separator: "\n") + "</p>\n"
            paragraph = []
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // fenced code block (highest priority)
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[i]); i += 1
                }
                i += 1   // skip closing fence (or EOF — unterminated runs to end)
                out += codeBlock(code.joined(separator: "\n"), language: lang)
                continue
            }
            // heading
            if let h = headingLevel(trimmed) {
                flushParagraph()
                let text = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                out += "<h\(h)>\(inline(text, baseDir: baseDir))</h\(h)>\n"
                i += 1; continue
            }
            // horizontal rule
            if isHR(trimmed) { flushParagraph(); out += "<hr>\n"; i += 1; continue }
            // blockquote: gather consecutive > lines, strip one level, recurse
            // (depth-capped; over the cap the > lines fall through to a paragraph)
            if trimmed.hasPrefix(">"), depth < maxQuoteDepth {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    quoted.append(String(t.dropFirst(t.hasPrefix("> ") ? 2 : 1)))
                    i += 1
                }
                out += "<blockquote>\(blocks(quoted, baseDir: baseDir, depth: depth + 1))</blockquote>\n"
                continue
            }
            // list (ordered/unordered/task, indent-nested) — collect the whole
            // list block and hand it to listBlock. Continuation detection matches
            // listMarker's indent rule: two spaces or one tab both count.
            if listMarker(line) != nil {
                flushParagraph()
                var block: [String] = []
                while i < lines.count, listMarker(lines[i]) != nil || (isListContinuation(lines[i]) && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty) {
                    block.append(lines[i]); i += 1
                }
                out += listBlock(block, baseDir: baseDir)
                continue
            }
            // GFM table：当前行含 | 且下一行是分隔行
            if line.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                var rows: [String] = [line, lines[i + 1]]
                i += 2
                while i < lines.count, lines[i].contains("|") { rows.append(lines[i]); i += 1 }
                out += tableBlock(rows, baseDir: baseDir)
                continue
            }
            // blank → paragraph break
            if trimmed.isEmpty { flushParagraph(); i += 1; continue }
            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return out
    }

    // MARK: helpers

    /// "#".."######" heading level, or nil. Requires at least one space (or
    /// end of line) after the hashes so "#tag" in a paragraph doesn't match.
    private static func headingLevel(_ trimmed: String) -> Int? {
        guard trimmed.hasPrefix("#") else { return nil }
        var count = 0
        for ch in trimmed {
            if ch == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6 else { return nil }
        let rest = trimmed.dropFirst(count)
        guard rest.isEmpty || rest.hasPrefix(" ") else { return nil }
        return count
    }

    /// `---`, `***`, `___` (>= 3 identical chars, optionally space-separated).
    private static func isHR(_ trimmed: String) -> Bool {
        guard !trimmed.isEmpty else { return false }
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    /// Detects a list-item marker on a raw (un-indent-stripped) line: `- `,
    /// `* `, `+ ` (unordered) or `N. ` / `N) ` (ordered). Returns the indent
    /// (leading whitespace width, tab = 1 level worth of columns handled by
    /// caller) and whether it's ordered — used by `listBlock`.
    private struct ListMarkerInfo { let indent: Int; let ordered: Bool; let rest: Substring }

    /// A non-marker line continues the current list item when it is indented —
    /// two spaces or one tab, mirroring `listMarker`'s indent counting.
    private static func isListContinuation(_ line: String) -> Bool {
        line.hasPrefix("  ") || line.hasPrefix("\t")
    }

    private static func listMarker(_ line: String) -> ListMarkerInfo? {
        var indent = 0
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == " " { indent += 1 } else if line[idx] == "\t" { indent += 2 } else { break }
            idx = line.index(after: idx)
        }
        let rest = line[idx...]
        if rest.hasPrefix("- ") { return ListMarkerInfo(indent: indent, ordered: false, rest: rest.dropFirst(2)) }
        if rest.hasPrefix("* ") { return ListMarkerInfo(indent: indent, ordered: false, rest: rest.dropFirst(2)) }
        if rest.hasPrefix("+ ") { return ListMarkerInfo(indent: indent, ordered: false, rest: rest.dropFirst(2)) }
        // ordered: digits then "." or ")" then space
        var digits = 0
        var i = rest.startIndex
        while i < rest.endIndex, rest[i].isNumber { digits += 1; i = rest.index(after: i) }
        if digits > 0, i < rest.endIndex, (rest[i] == "." || rest[i] == ")") {
            let after = rest.index(after: i)
            if after < rest.endIndex, rest[after] == " " {
                return ListMarkerInfo(indent: indent, ordered: true, rest: rest[rest.index(after: after)...])
            }
        }
        return nil
    }

    /// Builds nested `<ul>`/`<ol>` from a flat run of list-item lines using an
    /// indent stack: 2 spaces (or 1 tab) = one nesting level. Continuation
    /// lines indented under an item but without their own marker are appended
    /// to that item's text (lazy continuation).
    private static func listBlock(_ lines: [String], baseDir: URL?) -> String {
        struct Level { let indent: Int; let ordered: Bool; var openedLI: Bool }
        var out = ""
        var stack: [Level] = []
        var i = 0

        func openList(indent: Int, ordered: Bool) {
            stack.append(Level(indent: indent, ordered: ordered, openedLI: false))
            out += ordered ? "<ol>" : "<ul>"
        }
        func closeTopLI() {
            if let top = stack.last, top.openedLI {
                out += "</li>"
                stack[stack.count - 1].openedLI = false
            }
        }

        while i < lines.count {
            let line = lines[i]
            guard let marker = listMarker(line) else {
                // Continuation line (indented, no marker) — append as plain text
                // to the currently open item, if any.
                if let top = stack.last, top.openedLI {
                    out += "\n" + inline(line.trimmingCharacters(in: .whitespaces), baseDir: baseDir)
                }
                i += 1; continue
            }
            // Pop only levels strictly deeper than this marker's indent; a
            // same-indent type change (ul↔ol) is handled by the `else if` below.
            while let top = stack.last, marker.indent < top.indent {
                closeTopLI()
                let level = stack.removeLast()
                out += level.ordered ? "</ol>" : "</ul>"
            }
            if stack.isEmpty || marker.indent > stack.last!.indent {
                // New nested level. If the parent item is open, nest the new
                // list INSIDE that <li> (before its closing tag) — do not close it.
                openList(indent: marker.indent, ordered: marker.ordered)
            } else if stack.last!.ordered != marker.ordered {
                // Same indent but different list type: close and reopen.
                closeTopLI()
                let level = stack.removeLast()
                out += level.ordered ? "</ol>" : "</ul>"
                openList(indent: marker.indent, ordered: marker.ordered)
            } else {
                // Same level, next item.
                closeTopLI()
            }

            var text = String(marker.rest)
            var checkbox = ""
            if text.hasPrefix("[ ] ") {
                checkbox = "<input type=\"checkbox\" disabled>"
                text = String(text.dropFirst(4))
            } else if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                checkbox = "<input type=\"checkbox\" disabled checked>"
                text = String(text.dropFirst(4))
            }
            out += "<li>" + checkbox + inline(text, baseDir: baseDir)
            stack[stack.count - 1].openedLI = true
            i += 1
        }
        while !stack.isEmpty {
            closeTopLI()
            let level = stack.removeLast()
            out += level.ordered ? "</ol>" : "</ul>"
        }
        return out + "\n"
    }

    /// GFM table separator row: `---|---` / `:--|--:` etc.
    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-") else { return false }
        let cells = t.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty else { return false }
            return c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// Splits a table row on `|`, dropping one optional leading/trailing
    /// empty cell produced by a leading/trailing pipe (`| a | b |` → ["a",
    /// "b"], not ["", "a", "b", ""]).
    private static func tableCells(_ row: String) -> [String] {
        var cells = row.components(separatedBy: "|")
        if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeFirst() }
        if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// GFM table: `rows[0]` is the header, `rows[1]` the alignment row
    /// (`:--` left / `--:` right / `:-:` center / plain `-` no alignment),
    /// the rest are data rows. Cell content is inline-parsed.
    private static func tableBlock(_ rows: [String], baseDir: URL?) -> String {
        guard rows.count >= 2 else { return "" }
        let headerCells = tableCells(rows[0])
        let aligns: [String?] = tableCells(rows[1]).map { spec in
            let left = spec.hasPrefix(":")
            let right = spec.hasSuffix(":")
            if left, right { return "center" }
            if left { return "left" }
            if right { return "right" }
            return nil
        }
        func alignAttr(_ index: Int) -> String {
            guard index < aligns.count, let a = aligns[index] else { return "" }
            return " style=\"text-align:\(a)\""
        }
        var out = "<table>\n<thead><tr>"
        for (idx, cell) in headerCells.enumerated() {
            out += "<th\(alignAttr(idx))>\(inline(cell, baseDir: baseDir))</th>"
        }
        out += "</tr></thead>\n<tbody>\n"
        for row in rows.dropFirst(2) {
            out += "<tr>"
            for (idx, cell) in tableCells(row).enumerated() {
                out += "<td\(alignAttr(idx))>\(inline(cell, baseDir: baseDir))</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody>\n</table>\n"
        return out
    }

    /// Fenced code：语言可识别 → SyntaxHighlighter token 着色 <span class="kw|str|com|num">
    private static func codeBlock(_ code: String, language: String) -> String {
        let escaped: String
        if let spec = LanguageSpec.language(forExtension: language) {
            escaped = highlightedHTML(code, spec: spec)   // 逐 token 切片、每片 escapeHTML、token 片包 span
        } else {
            escaped = escapeHTML(code)
        }
        return "<pre><code>\(escaped)</code></pre>\n"
    }

    /// Slices `code` by `SyntaxHighlighter` token ranges into alternating
    /// plain/colored segments (tokens are position-ordered, non-overlapping),
    /// escaping every segment and wrapping colored ones in a `<span>`.
    private static func highlightedHTML(_ code: String, spec: LanguageSpec) -> String {
        let tokens = SyntaxHighlighter.tokenize(code, spec: spec)
        let ns = code as NSString
        var out = ""
        var cursor = 0
        for token in tokens {
            guard token.range.location >= cursor else { continue }   // defensive: skip overlap
            if token.range.location > cursor {
                out += escapeHTML(ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor)))
            }
            let text = ns.substring(with: token.range)
            out += "<span class=\"\(cssClass(for: token.kind))\">\(escapeHTML(text))</span>"
            cursor = NSMaxRange(token.range)
        }
        if cursor < ns.length {
            out += escapeHTML(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }
        return out
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

    /// Inline parser (design §4.2). Order: backslash escape → inline code →
    /// image → link → strong (**/__) → em (*/_) → del (~~). Content inside
    /// strong/em/link text is parsed recursively; inline code is not.
    static func inline(_ text: String, baseDir: URL?) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        // Start index of the current run of consecutive markup-free
        // characters, or nil when no run is open. The run is sliced and
        // escaped in one batch at flush — per-character escapeHTML(String(c))
        // has a heavy constant factor (5.4s on a 2MB single line, vs. well
        // under a second batched).
        var runStart: Int? = nil
        func flushPlain() {
            guard let start = runStart else { return }
            out += escapeHTML(String(chars[start..<i]))
            runStart = nil
        }

        // Element-wise comparison — building an Array slice per scanned
        // position allocates and dominates runtime on large inputs.
        func find(_ marker: [Character], from: Int) -> Int? {
            let mc = marker.count
            guard mc > 0, chars.count >= mc else { return nil }
            var j = from
            while j <= chars.count - mc {
                if chars[j] == marker[0] {
                    var ok = true
                    for k in 1..<mc where chars[j + k] != marker[k] { ok = false; break }
                    if ok { return j }
                }
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
        func matchDelimited(_ marker: String, tag: String) -> Bool {
            let m = Array(marker)
            guard i + m.count <= chars.count else { return false }
            for k in 0..<m.count where chars[i + k] != m[k] { return false }
            guard var close = find(m, from: i + m.count), close > i + m.count else { return false }
            // Align the closing delimiter to the END of its run of identical
            // characters, so "**bold *and em***" closes the outer "**" on the
            // last two "*" of the trailing "***" run — leaving "bold *and em*"
            // as the inner content, whose single "*" pair recurses into <em>.
            while close + m.count < chars.count, chars[close + m.count] == m[0] { close += 1 }
            let inner = String(chars[(i + m.count)..<close])
            flushPlain()
            out += "<\(tag)>" + inline(inner, baseDir: baseDir) + "</\(tag)>"
            i = close + m.count
            return true
        }

        while i < chars.count {
            let c = chars[i]
            // Backslash escape: \ + punctuation/symbol → literal character.
            // Flush the run up to the backslash, then resume the run AT the
            // escaped character (skipping only the backslash itself) so it
            // still gets batch-escaped with whatever plain text follows.
            if c == "\\", i + 1 < chars.count, (chars[i + 1].isPunctuation || chars[i + 1].isSymbol) {
                flushPlain()
                runStart = i + 1
                i += 2; continue
            }
            // Inline code — content is NOT parsed further.
            if c == "`", let close = find(["`"], from: i + 1) {
                flushPlain()
                out += "<code>" + escapeHTML(String(chars[(i + 1)..<close])) + "</code>"
                i = close + 1; continue
            }
            // Image.
            if c == "!", i + 1 < chars.count, chars[i + 1] == "[",
               let (alt, url, next) = bracketPair(chars, from: i + 1) {
                flushPlain()
                out += imageHTML(alt: alt, src: url, baseDir: baseDir); i = next; continue
            }
            // Link.
            if c == "[", let (label, url, next) = bracketPair(chars, from: i) {
                flushPlain()
                out += "<a href=\"\(escapeHTML(url))\">\(inline(label, baseDir: baseDir))</a>"
                i = next; continue
            }
            // Strong / del must be checked before single-char em, since "**"
            // begins with a character that also has a single-char meaning
            // ("*"); "__" likewise must precede "_". Dispatch on the first
            // character so ordinary text skips all delimiter machinery —
            // calling matchDelimited 5x per character dominated large inputs.
            if c == "*" {
                if matchDelimited("**", tag: "strong") { continue }
                if matchDelimited("*", tag: "em") { continue }
            } else if c == "_" {
                if matchDelimited("__", tag: "strong") { continue }
                if matchDelimited("_", tag: "em") { continue }
            } else if c == "~" {
                if matchDelimited("~~", tag: "del") { continue }
            }
            if runStart == nil { runStart = i }
            i += 1
        }
        flushPlain()
        return out
    }

    /// Scan caps for `bracketPair`. Without them a flood of `[` characters
    /// makes every position run a failing O(n) scan — quadratic overall
    /// (measured: 50K `[` took 41s; a 2MB file extrapolates to hours, on the
    /// main thread). 999 is the CommonMark link-label limit; 4096 is a
    /// generous URL bound. Past the cap the pattern fails fast and the `[`
    /// renders literally — flood inputs are linear again.
    private static let maxLinkLabelLength = 999
    private static let maxLinkURLLength = 4096

    /// Parses `[label](url)` starting at `from` (which must point at the
    /// opening `[`). No nested brackets/parens are supported inside label or
    /// url (accepted degradation). Returns (label, url, index just past the
    /// closing `)`), or nil if the pattern doesn't match.
    private static func bracketPair(_ chars: [Character], from: Int) -> (String, String, Int)? {
        // Hoisted out of the scan loops: building a Character from a literal
        // per iteration is a measurable constant in unoptimized builds.
        let closeBracket: Character = "]"
        let closeParen: Character = ")"
        guard from < chars.count, chars[from] == "[" else { return nil }
        var j = from + 1
        let labelStart = j
        // Length caps use index arithmetic, NOT String.count (which is O(n)
        // and would reintroduce quadratic cost inside the capped scan). The
        // scan window is also bounded up front so the cap costs one min().
        var limit = min(chars.count, labelStart + maxLinkLabelLength + 1)
        while j < limit, chars[j] != closeBracket { j += 1 }
        guard j < chars.count, chars[j] == closeBracket, j - labelStart <= maxLinkLabelLength else { return nil }
        let label = String(chars[labelStart..<j])
        j += 1
        guard j < chars.count, chars[j] == "(" else { return nil }
        j += 1
        let urlStart = j
        limit = min(chars.count, urlStart + maxLinkURLLength + 1)
        while j < limit, chars[j] != closeParen { j += 1 }
        guard j < chars.count, chars[j] == closeParen, j - urlStart <= maxLinkURLLength else { return nil }
        let url = String(chars[urlStart..<j])
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

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
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
    """
}
