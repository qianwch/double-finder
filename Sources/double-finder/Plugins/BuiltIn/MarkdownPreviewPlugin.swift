import AppKit
import DoubleFinderPluginKit

/// Built-in page viewer: Markdown (`.md` / `.markdown`) and standalone diagram
/// sources (`.mmd` / `.puml` / `.plantuml`) rendered as a page in the Lister.
/// Phase 1 returns the converted document with diagram placeholders (source
/// visible immediately); phase 2 renders every mermaid / PlantUML block to SVG
/// on the main actor and pushes the substituted page through `update`.
/// Switch it off in Settings ▸ Plugins and F3 shows Markdown as highlighted
/// source instead.
final class MarkdownPreviewPlugin: NSObject, DFPlugin {
    static let identifier = "net.qian.double-finder.markdown"

    var info: PluginInfo {
        MainActor.assumeIsolated { PluginInfo(identifier: Self.identifier, name: tr("Markdown Preview"), version: "1.0",
                   summary: tr("Renders Markdown, mermaid and PlantUML files as a page in the Lister"),
                   author: "Double Finder") }
    }

    private let viewer = MarkdownPageViewer()

    override init() { super.init() }

    func activate(host: PluginHost) throws {}

    var pageViewers: [PageViewerPlugin] { [viewer] }
}

/// The `PageViewerPlugin` behind `MarkdownPreviewPlugin`. Thread-safe by
/// construction: `renderPage` touches only locals; `lastDiagramDark` is the one
/// shared field and is guarded.
final class MarkdownPageViewer: PageViewerPlugin, @unchecked Sendable {
    let identifier = "markdown"
    var displayName: String { MainActor.assumeIsolated { tr("Markdown Preview") } }

    /// Max size read fully into memory to render (design §4.1).
    static let maxBytes = 50 << 20

    /// Theme baked into the SVGs of the page currently showing; nil = the last
    /// page had no rendered diagrams (its CSS adapts by itself).
    private var lastDiagramDark: Bool?
    private let lock = NSLock()

    /// Which markup a file holds by extension; nil = not ours.
    enum Kind { case markdown, diagram(DiagramKind) }

    static func kind(of url: URL) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .markdown
        case "mmd": return .diagram(.mermaid)
        case "puml", "plantuml": return .diagram(.plantuml)
        default: return nil
        }
    }

    func canRender(url: URL, sample: Data) -> Bool {
        // A "markdown" file full of NULs is binary in disguise: leave it to the
        // hex sniff instead of rendering garbage.
        Self.kind(of: url) != nil && ViewerModeChooser.looksLikeText(sample)
    }

    func renderPage(url: URL, isCancelled: @escaping @Sendable () -> Bool,
                    update: @escaping @Sendable (Result<String, Error>) -> Void) throws -> String {
        guard let kind = Self.kind(of: url) else { throw PageError("Read error — cannot access the file") }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        // Size-before-read (order is critical: never read a huge md fully into memory).
        guard size <= Self.maxBytes else { throw PageError("Markdown too large — showing source") }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw PageError("Read error — cannot access the file")
        }
        var decoder = TextChunkDecoder(encoding: EncodingDetector.detect(sample: data.prefix(64 << 10)))
        let text = decoder.decode(data, isFinal: true)
        let doc: (html: String, diagrams: [DiagramBlock])
        var standalone = false
        switch kind {
        case .markdown:
            doc = MarkdownToHTML.renderDocument(text, baseDir: url.deletingLastPathComponent(), isCancelled: isCancelled)
        case .diagram(let dk):
            // Standalone .mmd/.puml = a synthesized one-fence document, so
            // phase 1 (source visible) and phase 2 (SVG) reuse the md path.
            standalone = true
            let fence = dk == .mermaid ? "mermaid" : "plantuml"
            doc = MarkdownToHTML.renderDocument("```\(fence)\n\(text)\n```", baseDir: nil, isCancelled: isCancelled)
        }
        if isCancelled() { throw CancellationError() }
        lock.withLock { lastDiagramDark = nil }
        if !doc.diagrams.isEmpty {
            resolveDiagrams(doc, standalone: standalone, isCancelled: isCancelled, update: update)
        }
        return doc.html
    }

    /// Phase 2 (design §5): render every diagram block to SVG (cache hits are
    /// instant), then hand the final page over ONCE. The scroll position resets
    /// — accepted (§5.6): the file was just opened. A standalone diagram file
    /// whose single block fails reports a failure so the host falls back to
    /// text mode (search / encoding beat a code block in a web view).
    private func resolveDiagrams(_ doc: (html: String, diagrams: [DiagramBlock]), standalone: Bool,
                                 isCancelled: @escaping @Sendable () -> Bool,
                                 update: @escaping @Sendable (Result<String, Error>) -> Void) {
        Task { @MainActor [weak self] in
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            var results: [Int: MarkdownToHTML.DiagramSubstitute] = [:]
            var failureNote: String?
            for (idx, block) in doc.diagrams.enumerated() {
                if isCancelled() { return }
                let r = await DiagramRenderer.shared.render(
                    DiagramRequest(kind: block.kind, source: block.source, dark: dark))
                switch r {
                case .svg(let svg): results[idx] = .svg(svg)
                case .failure(let note):
                    results[idx] = .failureNote(tr(note))
                    failureNote = note
                }
            }
            guard let self, !isCancelled() else { return }
            if standalone, let note = failureNote {
                update(.failure(PageError(note)))
                return
            }
            guard !results.isEmpty else { return }
            // Only count the theme as "baked in" when at least one SVG landed —
            // an all-failure page has nothing theme-dependent to re-render.
            let anySVG = results.values.contains { if case .svg = $0 { return true } else { return false } }
            self.lock.withLock { self.lastDiagramDark = anySVG ? dark : nil }
            update(.success(MarkdownToHTML.substituteDiagrams(doc.html, diagrams: doc.diagrams, results: results)))
        }
    }

    /// Mermaid themes are BAKED into the rendered SVG (unlike the page CSS,
    /// which adapts via prefers-color-scheme): re-render when the shown SVGs
    /// were made for the other appearance. Cache keyed by theme makes it instant.
    func needsRerenderOnAppearanceChange() -> Bool {
        guard let last = lock.withLock({ lastDiagramDark }) else { return false }
        let dark = MainActor.assumeIsolated { NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
        return dark != last
    }
}

/// Error whose `localizedDescription` is the status-bar note the host should
/// show. Built-in plugins pass the ENGLISH source string (they run off the
/// main actor, where `tr()` is not available); the host translates at the
/// display site — identity fallback for a bundle's own free-form message.
struct PageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
