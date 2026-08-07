import Foundation

/// Diagram code-fence kinds rendered to SVG in the Lister markdown preview
/// (design §2). `plantuml` and `puml` are aliases.
enum DiagramKind: String {
    case mermaid, plantuml

    init?(fenceLanguage: String) {
        switch fenceLanguage.lowercased() {
        case "mermaid": self = .mermaid
        case "plantuml", "puml": self = .plantuml
        default: return nil
        }
    }
}

/// One extracted diagram block, in document order (index = data-idx).
struct DiagramBlock: Equatable {
    let kind: DiagramKind
    let source: String
}

/// Pure helpers shared by the diagram pipeline (design §3.3) — all unit-tested.
enum DiagramSupport {

    /// PlantUML's -pipe input must be a complete @start…@end document; md fences
    /// usually include it but bare snippets are wrapped as @startuml.
    static func wrappedPlantUML(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("@start") { return source }
        return "@startuml\n\(source)\n@enduml"
    }

    /// Defense-in-depth scrub of renderer-produced SVG before it is inlined into
    /// the (JS-disabled) main preview page: script blocks, on* event attributes
    /// and javascript: hrefs go; anything before the root <svg (XML prolog,
    /// DOCTYPE) is dropped because it breaks inline-in-HTML embedding.
    /// Unquoted attribute values (`onload=x`, `href=javascript:…`) are out of
    /// scope — acceptable because the main webview has JS disabled anyway.
    static func sanitizeSVG(_ svg: String) -> String {
        var s = svg
        if let r = s.range(of: "<svg", options: .caseInsensitive) {
            s = String(s[r.lowerBound...])
        }
        let patterns = [
            "<script\\b[^>]*>[\\s\\S]*?</script\\s*>",
            "<script\\b[^>]*/>",
            "\\son[a-zA-Z]+\\s*=\\s*\"[^\"]*\"",
            "\\son[a-zA-Z]+\\s*=\\s*'[^']*'",
            "\\s(?:xlink:)?href\\s*=\\s*\"\\s*javascript:[^\"]*\"",
            "\\s(?:xlink:)?href\\s*=\\s*'\\s*javascript:[^']*'",
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s
    }

    /// Dev bare-run fallback: resolve vendor/<rel> from the repo root derived
    /// from this source file's compile-time path. Packaged apps run from
    /// elsewhere, so the probe naturally fails there (design §6).
    static func devVendorPath(_ rel: String) -> String? {
        let root = URL(fileURLWithPath: #filePath)   // …/Sources/double-finder/Utils/Lister/DiagramSupport.swift
            .deletingLastPathComponent()             // Lister
            .deletingLastPathComponent()             // Utils
            .deletingLastPathComponent()             // double-finder
            .deletingLastPathComponent()             // Sources
            .deletingLastPathComponent()             // repo root
        let p = root.appendingPathComponent("vendor/" + rel).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }
}

/// In-memory LRU for rendered SVG (design §3.4). NOT thread-safe — main actor
/// use only (DiagramRenderer owns the single instance).
final class DiagramCache {
    private let capacity: Int
    private var store: [String: String] = [:]
    private var order: [String] = []           // LRU order, most recent LAST

    init(capacity: Int = 32) { self.capacity = capacity }

    static func key(kind: DiagramKind, source: String, dark: Bool) -> String {
        "\(kind.rawValue)|\(dark ? "d" : "l")|\(source)"
    }

    func get(_ key: String) -> String? {
        guard let v = store[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return v
    }

    func set(_ key: String, _ value: String) {
        if store[key] == nil, store.count >= capacity, let oldest = order.first {
            order.removeFirst()
            store[oldest] = nil
        }
        store[key] = value
        order.removeAll { $0 == key }
        order.append(key)
    }
}
