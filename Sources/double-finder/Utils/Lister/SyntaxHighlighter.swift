import Foundation

/// Lexical (not semantic) highlighter — design §3. Line-based single pass:
/// only the block-comment state crosses lines; strings stop at EOL (damage
/// containment); line rules (markdown/yaml) run before character scanning.
/// Input is the FULL decoded string of a ≤4MB file (single chunk, no carry),
/// so utf16 offsets map 1:1 onto the textStorage the caller colors.
/// Perf: the <100ms/4MB budget is a RELEASE-build number — debug builds are
/// several× slower (array bounds checks on every `chars[i]` access); don't
/// use a debug timing to judge whether the budget is met.
enum SyntaxHighlighter {
    struct Token: Equatable {
        let range: NSRange   // utf16, ready for textStorage.addAttribute
        let kind: TokenKind
    }

    /// Spec patterns pre-converted to UTF-16 code units once per `tokenize` call,
    /// instead of re-deriving `Array(needle.utf16)` / `String(delim).utf16.first`
    /// at every scan position — that per-character heap churn was the hot-path
    /// cost (178–424ms on 4MB files, measured before this change).
    private struct CompiledSpec {
        let keywords: Set<String>
        let lineCommentPrefixes: [[UInt16]]
        let blockOpen: [UInt16]?
        let blockClose: [UInt16]?
        let stringDelimiters: [(unit: UInt16, escapable: Bool)]
        let lineRules: [(prefix: [UInt16], kind: TokenKind)]
        let keySeparator: UInt16?

        init(_ spec: LanguageSpec) {
            keywords = spec.keywords
            lineCommentPrefixes = spec.lineCommentPrefixes.map { Array($0.utf16) }
            blockOpen = spec.blockComment.map { Array($0.open.utf16) }
            blockClose = spec.blockComment.map { Array($0.close.utf16) }
            stringDelimiters = spec.stringDelimiters.compactMap { d in
                String(d.delim).utf16.first.map { (unit: $0, escapable: d.escapable) }
            }
            lineRules = spec.lineRules.map { (prefix: Array($0.prefix.utf16), kind: $0.kind) }
            keySeparator = spec.keyValueSeparator.flatMap { String($0).utf16.first }
        }
    }

    static func tokenize(_ text: String, spec: LanguageSpec) -> [Token] {
        var tokens: [Token] = []
        var inBlockComment = false
        let compiled = CompiledSpec(spec)
        let ns = text as NSString
        var lineStart = 0
        while lineStart < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            // Content range without the trailing newline.
            var contentEnd = NSMaxRange(lineRange)
            while contentEnd > lineRange.location,
                  let ch = Unicode.Scalar(ns.character(at: contentEnd - 1)), CharacterSet.newlines.contains(ch) {
                contentEnd -= 1
            }
            let line = ns.substring(with: NSRange(location: lineRange.location,
                                                  length: contentEnd - lineRange.location))
            scanLine(line, at: lineRange.location, spec: compiled,
                     inBlockComment: &inBlockComment, into: &tokens)
            lineStart = NSMaxRange(lineRange)
        }
        return tokens
    }

    // MARK: per-line scan

    private static func scanLine(_ line: String, at base: Int, spec: CompiledSpec,
                                 inBlockComment: inout Bool, into tokens: inout [Token]) {
        let chars = Array(line.utf16)
        let count = chars.count
        func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
            guard end > start else { return }
            tokens.append(Token(range: NSRange(location: base + start, length: end - start), kind: kind))
        }
        func matches(_ n: [UInt16], at i: Int) -> Bool {
            guard i + n.count <= count else { return false }
            for j in 0..<n.count where chars[i + j] != n[j] { return false }
            return true
        }
        var i = 0

        // Continuing a multi-line block comment: comment until close or EOL.
        // Invariant: `inBlockComment` is only ever set true below when
        // `spec.blockOpen`/`blockClose` are non-nil (a spec with no block
        // comment never sets it), and `tokenize` threads one `spec` across
        // every line of a single call — so the force-unwrap here is safe.
        // Any future incremental/partial-rehighlight entry point that carries
        // `inBlockComment` across a *different* spec must re-establish this
        // invariant itself (e.g. by resetting the flag on language change).
        if inBlockComment {
            let close = spec.blockClose!
            var j = 0
            while j <= count - close.count {
                if matches(close, at: j) {
                    emit(0, j + close.count, .comment)
                    inBlockComment = false
                    i = j + close.count
                    break
                }
                j += 1
            }
            if inBlockComment { emit(0, count, .comment); return }
        }

        // Line rules first (markdown/yaml): whole-line or key-prefix coloring.
        if i == 0 {
            // Leading whitespace is trimmed with no column limit before matching
            // lineRules/key rule below — intentional: yaml nested keys can sit at
            // any indent, and it's a deliberate (accepted) lexical-level departure
            // from CommonMark's 0-3-space rule for markdown headings (e.g.
            // "    # x" still colors as a heading here).
            let trimmedStart = firstNonSpace(chars)
            for rule in spec.lineRules where matchesPrefix(rule.prefix, chars, from: trimmedStart) {
                emit(trimmedStart, count, rule.kind)
                return
            }
            // yaml/toml key rule: bare word from line start to separator.
            if let sep = spec.keySeparator, let sepIdx = keyEnd(chars, from: trimmedStart, separator: sep) {
                emit(trimmedStart, sepIdx, .keyword)
                i = sepIdx   // continue normal scan after the key
            }
        }

        // Character scan.
        while i < count {
            // block comment open
            if let open = spec.blockOpen, matches(open, at: i) {
                let close = spec.blockClose!
                var j = i + open.count
                var closed = false
                while j <= count - close.count {
                    if matches(close, at: j) { emit(i, j + close.count, .comment); i = j + close.count; closed = true; break }
                    j += 1
                }
                if !closed { emit(i, count, .comment); inBlockComment = true; return }
                continue
            }
            // line comment
            if spec.lineCommentPrefixes.contains(where: { matches($0, at: i) }) {
                emit(i, count, .comment); return
            }
            // string
            if let d = spec.stringDelimiters.first(where: { $0.unit == chars[i] }) {
                var j = i + 1
                while j < count {
                    if d.escapable && chars[j] == 0x5C /* \ */ { j += 2; continue }
                    if chars[j] == d.unit { j += 1; break }
                    j += 1
                }
                emit(i, min(j, count), .string); i = min(j, count); continue
            }
            // number (word boundary: previous char must not be identifier)
            if isDigit(chars[i]), i == 0 || !isIdentChar(chars[i - 1]) {
                var j = i + 1
                if chars[i] == 0x30 /* 0 */, j < count, chars[j] == 0x78 || chars[j] == 0x58 { // 0x / 0X
                    j += 1
                    while j < count, isHexDigit(chars[j]) { j += 1 }
                } else {
                    while j < count, isDigit(chars[j]) || chars[j] == 0x2E /* . */ { j += 1 }
                }
                emit(i, j, .number); i = j; continue
            }
            // identifier / keyword
            if isIdentStart(chars[i]) {
                var j = i + 1
                while j < count, isIdentChar(chars[j]) { j += 1 }
                let word = String(utf16CodeUnits: Array(chars[i..<j]), count: j - i)
                if spec.keywords.contains(word) { emit(i, j, .keyword) }
                i = j; continue
            }
            i += 1
        }
    }

    // MARK: - Character-class helpers (UTF-16 code unit level)

    private static func isDigit(_ c: UInt16) -> Bool {
        c >= 0x30 && c <= 0x39 // '0'...'9'
    }

    private static func isHexDigit(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) // 'A'...'F', 'a'...'f'
    }

    private static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F /* _ */ || c > 0x7F
        // ASCII letters, underscore, or any non-ASCII scalar (Unicode identifiers, e.g. CJK names).
    }

    private static func isIdentChar(_ c: UInt16) -> Bool {
        isIdentStart(c) || isDigit(c)
    }

    /// yaml/toml key characters: identifier chars plus hyphen (common in yaml keys),
    /// deliberately distinct from `isIdentChar` used for language identifiers.
    private static func isKeyChar(_ c: UInt16) -> Bool {
        isIdentChar(c) || c == 0x2D /* - */
    }

    private static func firstNonSpace(_ chars: [UInt16]) -> Int {
        var i = 0
        while i < chars.count, chars[i] == 0x20 /* space */ || chars[i] == 0x09 /* tab */ { i += 1 }
        return i
    }

    private static func matchesPrefix(_ p: [UInt16], _ chars: [UInt16], from start: Int) -> Bool {
        guard !p.isEmpty, start + p.count <= chars.count else { return false }
        for j in 0..<p.count where chars[start + j] != p[j] { return false }
        return true
    }

    /// Finds the separator ending a yaml/toml bare key, starting at `start`.
    /// Contract (plan review): every char from `start` up to (not including) the
    /// separator must be a key char, and the span must be non-empty — a naive
    /// "find the first separator" would misfire on comment lines like
    /// `# url: http://x`, coloring "# url" as a key and never reaching the
    /// line-comment branch. Any non-key char before the separator aborts (nil).
    private static func keyEnd(_ chars: [UInt16], from start: Int, separator sepUnit: UInt16) -> Int? {
        var i = start
        while i < chars.count, chars[i] != sepUnit {
            guard isKeyChar(chars[i]) else { return nil }
            i += 1
        }
        guard i < chars.count, i > start else { return nil }
        return i
    }
}
