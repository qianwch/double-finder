import Foundation

/// Token color classes the highlighter can emit (design §3.1).
enum TokenKind {
    case keyword, string, comment, number
}

/// Declarative lexing rules for one language (design §2) — SIX field classes
/// only; anything a language needs must be expressible here. This table is
/// consumed by the Task 2 tokenizer/highlighter; it contains no lexing logic
/// itself, only data.
struct LanguageSpec {
    let name: String
    let keywords: Set<String>
    let lineCommentPrefixes: [String]
    let blockComment: (open: String, close: String)?
    /// (delimiter, supports backslash escape)
    let stringDelimiters: [(delim: Character, escapable: Bool)]
    /// Line-start prefix → color the WHOLE line. Applied BEFORE the five
    /// character-level rules (markdown headings/quotes/fences).
    let lineRules: [(prefix: String, kind: TokenKind)]
    /// Bare word from line start up to this separator → keyword (yaml/toml).
    let keyValueSeparator: Character?

    static func language(forExtension ext: String) -> LanguageSpec? {
        byExtension[ext.lowercased()]
    }

    // MARK: - Language definitions

    static let swiftLang = LanguageSpec(
        name: "swift",
        keywords: [
            "func", "let", "var", "if", "else", "guard", "for", "while", "switch", "case",
            "return", "struct", "class", "enum", "protocol", "extension", "import", "init",
            "self", "Self", "nil", "true", "false", "in", "where", "do", "try", "catch",
            "throw", "throws", "async", "await", "static", "private", "public", "internal",
            "fileprivate", "open", "override", "final", "lazy", "weak", "unowned", "typealias",
            "mutating", "defer", "as", "is", "inout", "break", "continue", "default", "fallthrough",
            "repeat", "subscript", "associatedtype", "some", "any", "rethrows"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let cFamily = LanguageSpec(
        name: "c",
        keywords: [
            "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
            "return", "goto", "struct", "class", "enum", "union", "typedef", "sizeof", "static",
            "const", "volatile", "extern", "inline", "void", "int", "char", "float", "double",
            "long", "short", "unsigned", "signed", "namespace", "template", "public", "private",
            "protected", "virtual", "new", "delete", "nullptr", "using", "bool", "true", "false",
            "try", "catch", "throw", "friend", "operator", "this", "auto", "explicit", "mutable"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let java = LanguageSpec(
        name: "java",
        keywords: [
            "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue",
            "return", "class", "interface", "enum", "extends", "implements", "package", "import",
            "public", "private", "protected", "static", "final", "abstract", "synchronized",
            "volatile", "transient", "native", "void", "int", "char", "float", "double", "long",
            "short", "boolean", "byte", "new", "this", "super", "try", "catch", "finally", "throw",
            "throws", "instanceof", "null", "true", "false", "assert", "enum"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let kotlin = LanguageSpec(
        name: "kotlin",
        keywords: [
            "fun", "val", "var", "if", "else", "for", "while", "do", "when", "return", "class",
            "interface", "object", "package", "import", "public", "private", "protected",
            "internal", "override", "open", "abstract", "final", "sealed", "data", "companion",
            "init", "this", "super", "try", "catch", "finally", "throw", "is", "as", "in", "null",
            "true", "false", "suspend", "inline", "reified", "vararg", "typealias", "constructor"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let javascript = LanguageSpec(
        name: "javascript",
        keywords: [
            "function", "var", "let", "const", "if", "else", "for", "while", "do", "switch",
            "case", "default", "break", "continue", "return", "class", "extends", "import",
            "export", "from", "new", "this", "super", "try", "catch", "finally", "throw",
            "instanceof", "typeof", "in", "of", "null", "undefined", "true", "false", "async",
            "await", "yield", "static", "get", "set", "delete", "void"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: true), (delim: "`", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let typescript = LanguageSpec(
        name: "typescript",
        keywords: javascript.keywords.union([
            "interface", "type", "enum", "implements", "declare", "readonly", "namespace",
            "public", "private", "protected", "abstract", "as", "is", "keyof", "infer", "never",
            "unknown", "any", "module"
        ]),
        lineCommentPrefixes: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: true), (delim: "`", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let goLang = LanguageSpec(
        name: "go",
        keywords: [
            "func", "var", "const", "if", "else", "for", "switch", "case", "default", "break",
            "continue", "return", "package", "import", "type", "struct", "interface", "map",
            "chan", "go", "defer", "select", "range", "true", "false", "nil", "iota", "fallthrough",
            "goto", "make", "new", "len", "cap", "append", "panic", "recover"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "`", escapable: false)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let rust = LanguageSpec(
        name: "rust",
        keywords: [
            "fn", "let", "mut", "if", "else", "for", "while", "loop", "match", "return", "struct",
            "enum", "trait", "impl", "mod", "use", "pub", "crate", "self", "Self", "super", "as",
            "in", "where", "async", "await", "move", "ref", "static", "const", "unsafe", "dyn",
            "true", "false", "None", "Some", "Ok", "Err", "break", "continue", "extern", "type"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let sql = LanguageSpec(
        name: "sql",
        keywords: {
            let base = [
                "select", "from", "where", "insert", "update", "delete", "into", "values", "set",
                "join", "inner", "left", "right", "outer", "on", "group", "by", "order", "having",
                "and", "or", "not", "null", "as", "create", "table", "drop", "alter", "index"
            ]
            return Set(base + base.map { $0.uppercased() })
        }(),
        lineCommentPrefixes: ["--"],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "'", escapable: false), (delim: "\"", escapable: false)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let python = LanguageSpec(
        name: "python",
        keywords: [
            "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
            "as", "try", "except", "finally", "raise", "with", "pass", "break", "continue",
            "lambda", "yield", "global", "nonlocal", "self", "None", "True", "False", "and",
            "or", "not", "in", "is", "async", "await", "del", "assert"
        ],
        lineCommentPrefixes: ["#"],
        blockComment: nil,
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let json = LanguageSpec(
        name: "json",
        keywords: [],
        lineCommentPrefixes: [],
        blockComment: nil,
        stringDelimiters: [(delim: "\"", escapable: true)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let xmlHTML = LanguageSpec(
        name: "xml",
        keywords: [],
        lineCommentPrefixes: [],
        blockComment: (open: "<!--", close: "-->"),
        stringDelimiters: [(delim: "\"", escapable: false), (delim: "'", escapable: false)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let css = LanguageSpec(
        name: "css",
        keywords: [],
        lineCommentPrefixes: [],
        blockComment: (open: "/*", close: "*/"),
        stringDelimiters: [(delim: "\"", escapable: false), (delim: "'", escapable: false)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let shell = LanguageSpec(
        name: "shell",
        keywords: [
            "if", "then", "else", "elif", "fi", "for", "do", "done", "while", "case", "esac",
            "function", "return", "exit", "echo", "export", "local", "in", "select", "until",
            "break", "continue", "readonly", "shift", "trap"
        ],
        lineCommentPrefixes: ["#"],
        blockComment: nil,
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: false)],
        lineRules: [],
        keyValueSeparator: nil
    )

    static let yaml = LanguageSpec(
        name: "yaml",
        keywords: ["true", "false", "null", "yes", "no"],
        lineCommentPrefixes: ["#"],
        blockComment: nil,
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: false)],
        lineRules: [],
        keyValueSeparator: ":"
    )

    static let toml = LanguageSpec(
        name: "toml",
        keywords: ["true", "false"],
        lineCommentPrefixes: ["#"],
        blockComment: nil,
        stringDelimiters: [(delim: "\"", escapable: true), (delim: "'", escapable: false)],
        lineRules: [],
        keyValueSeparator: "="
    )

    static let markdown = LanguageSpec(
        name: "markdown",
        keywords: [],
        lineCommentPrefixes: [],
        blockComment: nil,
        stringDelimiters: [],
        lineRules: [
            (prefix: "#", kind: .keyword),
            (prefix: ">", kind: .comment),
            (prefix: "```", kind: .string)
        ],
        keyValueSeparator: nil
    )

    // MARK: - Extension registry

    static let byExtension: [String: LanguageSpec] = [
        "swift": swiftLang,
        "c": cFamily, "h": cFamily, "cpp": cFamily, "hpp": cFamily, "cc": cFamily,
        "m": cFamily, "mm": cFamily,
        "java": java,
        "kt": kotlin, "kts": kotlin,
        "py": python,
        "js": javascript, "jsx": javascript, "mjs": javascript,
        "ts": typescript, "tsx": typescript,
        "json": json,
        "xml": xmlHTML, "html": xmlHTML, "htm": xmlHTML, "plist": xmlHTML, "svg": xmlHTML,
        "css": css,
        "sh": shell, "bash": shell, "zsh": shell,
        "yaml": yaml, "yml": yaml,
        "toml": toml,
        "sql": sql,
        "go": goLang,
        "rs": rust,
        "md": markdown, "markdown": markdown
    ]
}
