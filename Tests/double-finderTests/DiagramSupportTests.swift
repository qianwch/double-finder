import XCTest
@testable import double_finder

final class DiagramSupportTests: XCTestCase {

    // MARK: DiagramKind fence-language mapping

    func testFenceLanguageMapping() {
        XCTAssertEqual(DiagramKind(fenceLanguage: "mermaid"), .mermaid)
        XCTAssertEqual(DiagramKind(fenceLanguage: "Mermaid"), .mermaid)   // 大小写不敏感
        XCTAssertEqual(DiagramKind(fenceLanguage: "plantuml"), .plantuml)
        XCTAssertEqual(DiagramKind(fenceLanguage: "puml"), .plantuml)
        XCTAssertNil(DiagramKind(fenceLanguage: "swift"))
        XCTAssertNil(DiagramKind(fenceLanguage: ""))
    }

    // MARK: PlantUML @start 包裹

    func testWrappedPlantUMLAddsEnvelope() {
        XCTAssertEqual(DiagramSupport.wrappedPlantUML("A -> B"), "@startuml\nA -> B\n@enduml")
    }

    func testWrappedPlantUMLKeepsExistingEnvelope() {
        let uml = "@startuml\nA -> B\n@enduml"
        XCTAssertEqual(DiagramSupport.wrappedPlantUML(uml), uml)
        let mind = "@startmindmap\n* root\n@endmindmap"       // 任何 @start… 都算已包裹
        XCTAssertEqual(DiagramSupport.wrappedPlantUML(mind), mind)
    }

    func testWrappedPlantUMLTolerantOfLeadingBlank() {
        let src = "\n  @startuml\nA\n@enduml\n"
        XCTAssertEqual(DiagramSupport.wrappedPlantUML(src), src)   // 探测前 trim，原文返回
    }

    // MARK: SVG 清洗

    func testSanitizeStripsScriptBlocks() {
        let dirty = "<svg><script>alert(1)</script><rect/></svg>"
        let clean = DiagramSupport.sanitizeSVG(dirty)
        XCTAssertFalse(clean.lowercased().contains("<script"))
        XCTAssertTrue(clean.contains("<rect/>"))
    }

    func testSanitizeStripsEventHandlers() {
        let dirty = "<svg onload=\"evil()\"><g onclick='x()'>t</g></svg>"
        let clean = DiagramSupport.sanitizeSVG(dirty)
        XCTAssertFalse(clean.contains("onload"))
        XCTAssertFalse(clean.contains("onclick"))
        XCTAssertTrue(clean.contains("<g >t</g>") || clean.contains("<g>t</g>"))
    }

    func testSanitizeStripsJavascriptHref() {
        let dirty = "<svg><a href=\"javascript:evil()\">x</a><a xlink:href='javascript:y'>z</a></svg>"
        let clean = DiagramSupport.sanitizeSVG(dirty)
        XCTAssertFalse(clean.contains("javascript:"))
    }

    func testSanitizeDropsXMLPrologAndDoctype() {
        let dirty = "<?xml version=\"1.0\"?>\n<!DOCTYPE svg>\n<svg><rect/></svg>"
        let clean = DiagramSupport.sanitizeSVG(dirty)
        XCTAssertTrue(clean.hasPrefix("<svg"))
    }

    func testSanitizeKeepsInnocentSVG() {
        let ok = "<svg viewBox=\"0 0 10 10\"><a href=\"https://a.b\">l</a><text>on time</text></svg>"
        XCTAssertEqual(DiagramSupport.sanitizeSVG(ok), ok)   // "on time" 不能被误杀
    }

    // MARK: LRU 缓存

    func testCacheHitAndEviction() {
        let c = DiagramCache(capacity: 2)
        c.set("a", "1"); c.set("b", "2")
        XCTAssertEqual(c.get("a"), "1")      // touch a → b 变最旧
        c.set("c", "3")                       // 容量 2，逐出 b
        XCTAssertNil(c.get("b"))
        XCTAssertEqual(c.get("a"), "1")
        XCTAssertEqual(c.get("c"), "3")
    }

    func testCacheKeyDistinguishesKindAndTheme() {
        XCTAssertNotEqual(DiagramCache.key(kind: .mermaid, source: "x", dark: false),
                          DiagramCache.key(kind: .plantuml, source: "x", dark: false))
        XCTAssertNotEqual(DiagramCache.key(kind: .mermaid, source: "x", dark: false),
                          DiagramCache.key(kind: .mermaid, source: "x", dark: true))
    }

    func testCacheOverwriteSameKeyDoesNotEvict() {
        let c = DiagramCache(capacity: 2)
        c.set("a", "1"); c.set("b", "2"); c.set("a", "1x")   // 覆盖不算新增
        XCTAssertEqual(c.get("a"), "1x")
        XCTAssertEqual(c.get("b"), "2")
    }
}
