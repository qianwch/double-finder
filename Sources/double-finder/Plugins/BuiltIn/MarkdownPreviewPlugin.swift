import AppKit
import DoubleFinderPluginKit

/// Markdown page appearance, independent of the PDF preference; absent means follow the app.
enum MarkdownAppearanceOverride {
    static let defaultsKey = "MarkdownAppearance"
    static let changed = Notification.Name("MarkdownAppearanceChanged")

    /// nil = follow the app's appearance.
    @MainActor static var wantsDark: Bool? {
        get {
            switch UserDefaults.standard.string(forKey: defaultsKey) {
            case "dark": return true
            case "light": return false
            default: return nil
            }
        }
        set {
            guard newValue != wantsDark else { return }
            if let newValue {
                UserDefaults.standard.set(newValue ? "dark" : "light", forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static func needsDiagramRefresh(html: String, dark: Bool) -> Bool {
        html.hasPrefix("<!--df-markdown-diagrams:\(dark ? "light" : "dark")-->")
    }

    /// Both the page CSS and diagram SVGs use this same effective theme.
    @MainActor static var isDark: Bool {
        wantsDark ?? (NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }
}

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
/// construction: render and diagram theme state live in each returned page.
final class MarkdownPageViewer: PageViewerPlugin, @unchecked Sendable {
    let identifier = "markdown"
    var displayName: String { MainActor.assumeIsolated { tr("Markdown Preview") } }

    /// Max size read fully into memory to render (design §4.1).
    static let maxBytes = 50 << 20

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
            let dark = MarkdownAppearanceOverride.isDark
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
            // An appearance switch during the asynchronous render must never
            // publish SVGs made for the previous theme.
            guard dark == MarkdownAppearanceOverride.isDark else {
                resolveDiagrams(doc, standalone: standalone, isCancelled: isCancelled, update: update)
                return
            }
            if standalone, let note = failureNote {
                update(.failure(PageError(note)))
                return
            }
            guard !results.isEmpty else { return }
            // Only count the theme as "baked in" when at least one SVG landed —
            // an all-failure page has nothing theme-dependent to re-render.
            let anySVG = results.values.contains { if case .svg = $0 { return true } else { return false } }
            let marker = anySVG ? "<!--df-markdown-diagrams:\(dark ? "dark" : "light")-->" : ""
            update(.success(marker + MarkdownToHTML.substituteDiagrams(doc.html, diagrams: doc.diagrams, results: results)))
        }
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
