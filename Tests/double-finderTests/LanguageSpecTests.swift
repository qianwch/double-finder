import XCTest
@testable import double_finder

final class LanguageSpecTests: XCTestCase {
    func testExtensionMappingCoreLanguages() {
        XCTAssertEqual(LanguageSpec.language(forExtension: "swift")?.name, "swift")
        XCTAssertEqual(LanguageSpec.language(forExtension: "PY")?.name, "python")   // case-insensitive
        XCTAssertEqual(LanguageSpec.language(forExtension: "hpp")?.name, "c")       // family merge
        XCTAssertEqual(LanguageSpec.language(forExtension: "tsx")?.name, "typescript")
        XCTAssertEqual(LanguageSpec.language(forExtension: "yml")?.name, "yaml")
        XCTAssertEqual(LanguageSpec.language(forExtension: "markdown")?.name, "markdown")
    }

    func testUnknownExtensionIsNil() {
        XCTAssertNil(LanguageSpec.language(forExtension: "docx"))
        XCTAssertNil(LanguageSpec.language(forExtension: ""))
    }

    func testFieldShapes() throws {
        let sw = try XCTUnwrap(LanguageSpec.language(forExtension: "swift"))
        XCTAssertTrue(sw.keywords.contains("func"))
        XCTAssertEqual(sw.blockComment?.open, "/*")
        XCTAssertTrue(sw.lineCommentPrefixes.contains("//"))
        let py = try XCTUnwrap(LanguageSpec.language(forExtension: "py"))
        XCTAssertNil(py.blockComment)
        XCTAssertTrue(py.lineCommentPrefixes.contains("#"))
        let yaml = try XCTUnwrap(LanguageSpec.language(forExtension: "yaml"))
        XCTAssertEqual(yaml.keyValueSeparator, ":")
        let md = try XCTUnwrap(LanguageSpec.language(forExtension: "md"))
        XCTAssertTrue(md.lineRules.contains { $0.prefix == "#" && $0.kind == .keyword })
        XCTAssertTrue(md.lineRules.contains { $0.prefix == ">" && $0.kind == .comment })
        XCTAssertTrue(md.lineRules.contains { $0.prefix == "```" && $0.kind == .string })
    }

    func testRegistryCompleteness() {
        // 35 extension → language mappings registered (registry completeness guard).
        XCTAssertEqual(LanguageSpec.registeredExtensionCount, 35)
    }

    func testAllSpecsHaveNonEmptyName() {
        // Spot-check names across the registry (every LanguageSpec must self-identify).
        let extensions = ["swift", "c", "java", "kt", "py", "js", "ts", "json", "xml", "css",
                           "sh", "yaml", "toml", "sql", "go", "rs", "md"]
        for ext in extensions {
            let spec = LanguageSpec.language(forExtension: ext)
            XCTAssertNotNil(spec, "missing spec for extension \(ext)")
            XCTAssertFalse(spec?.name.isEmpty ?? true, "empty name for extension \(ext)")
        }
    }
}
