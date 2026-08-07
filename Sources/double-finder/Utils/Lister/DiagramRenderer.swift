import AppKit
import WebKit

/// One diagram to render (design §3). `dark` picks the mermaid theme and keys
/// the cache; plantuml ignores it (white-card CSS handles dark pages).
struct DiagramRequest {
    let kind: DiagramKind
    let source: String
    let dark: Bool
}

/// `failure` notes are ENGLISH source strings — tr() happens at the display
/// site (CLAUDE.md §5.8 pattern: translate only at @MainActor display time).
enum DiagramResult {
    case svg(String)
    case failure(note: String)
}

/// Async diagram-source → sanitized-SVG service (design §3). Mermaid renders in
/// a hidden off-screen WKWebView — the ONLY place JS runs; the main
/// ListerWebView keeps JS disabled (its trust model is untouched). PlantUML
/// runs `java -jar plantuml.jar -tsvg -pipe` off the main actor. Requests are
/// serialized; results are LRU-cached (kind+theme+source).
@MainActor
final class DiagramRenderer: NSObject, WKNavigationDelegate {
    static let shared = DiagramRenderer()

    static let mermaidTimeout: TimeInterval = 5
    nonisolated static let plantumlTimeout: TimeInterval = 15

    private let cache = DiagramCache()
    private var tail: Task<Void, Never>?           // FIFO serialization of renders

    // Mermaid shell: one hidden webview, built lazily, rebuilt on theme change
    // or after a render error / content-process crash.
    private var mermaidWebView: WKWebView?
    private var mermaidShellDark: Bool?
    private var shellLoadLatch: OneShotResume<Bool>?
    private var renderSeq = 0

    private override init() { super.init() }

    func render(_ req: DiagramRequest) async -> DiagramResult {
        let key = DiagramCache.key(kind: req.kind, source: req.source, dark: req.dark)
        if let hit = cache.get(key) { return .svg(hit) }
        let previous = tail
        let work = Task { () -> DiagramResult in
            _ = await previous?.value
            switch req.kind {
            case .mermaid: return await self.renderMermaid(req)
            case .plantuml: return await self.renderPlantUML(req)
            }
        }
        tail = Task { _ = await work.value }
        let result = await work.value
        if case .svg(let svg) = result { cache.set(key, svg) }
        return result
    }

    // MARK: Mermaid (off-screen WKWebView)

    private func mermaidJSPath() -> String? {
        if let res = Bundle.main.resourcePath {
            let p = res + "/mermaid.min.js"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return DiagramSupport.devVendorPath("mermaid/mermaid.min.js")
    }

    private func renderMermaid(_ req: DiagramRequest) async -> DiagramResult {
        guard let jsPath = mermaidJSPath() else {
            return .failure(note: "Mermaid renderer unavailable — showing source")
        }
        if mermaidWebView == nil || mermaidShellDark != req.dark {
            guard await buildMermaidShell(jsPath: jsPath, dark: req.dark) else {
                return .failure(note: "Mermaid renderer unavailable — showing source")
            }
        }
        guard let webView = mermaidWebView else {
            return .failure(note: "Mermaid renderer unavailable — showing source")
        }
        renderSeq += 1
        let body = """
        const r = await mermaid.render(id, src);
        return r.svg;
        """
        // Unstructured race, NOT a task group: a structured group implicitly
        // awaits its children, so a truly hung callAsyncJavaScript (dead web
        // process loop, completion never fires) would block past the deadline
        // AND wedge the FIFO render chain forever. The latch resumes exactly
        // once — on completion, error, or deadline — and a late completion of
        // a timed-out call is dropped (a leaked-but-harmless closure).
        let svg: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let latch = OneShotResume(c)
            webView.callAsyncJavaScript(body,
                                        arguments: ["src": req.source, "id": "m\(renderSeq)"],
                                        in: nil, in: .page) { result in
                if case .success(let value) = result { latch.resume(value as? String) }
                else { latch.resume(nil) }   // mermaid parse error → failure
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mermaidTimeout) { latch.resume(nil) }
        }
        guard let svg else {
            // Parse errors leave error DOM in the shell; timeouts leave it in an
            // unknown state — rebuild next time either way.
            resetMermaidShell()
            return .failure(note: "Diagram rendering failed — showing source")
        }
        return .svg(DiagramSupport.sanitizeSVG(svg))
    }

    /// One-shot latch so racing completion/timeout callbacks resume a
    /// continuation exactly once — used by both the render race and the
    /// shell-load race (a late delegate callback / JS completion after the
    /// deadline fired is silently dropped). @unchecked Sendable: every resume
    /// path lands on the main queue (WKWebView callbacks + main-queue
    /// asyncAfter), so the flag is main-thread confined — same pattern as
    /// IconOperation.
    private final class OneShotResume<T>: @unchecked Sendable {
        private var resumed = false
        private let continuation: CheckedContinuation<T, Never>
        init(_ c: CheckedContinuation<T, Never>) { continuation = c }
        func resume(_ value: T) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }

    private func resetMermaidShell() {
        mermaidWebView?.navigationDelegate = nil
        mermaidWebView = nil
        mermaidShellDark = nil
    }

    /// Loads an empty shell page, injects mermaid.min.js via evaluateJavaScript
    /// (NOT a <script> tag — the lib source could contain "</script>"), then
    /// initializes with the theme. securityLevel strict escapes labels.
    private func buildMermaidShell(jsPath: String, dark: Bool) async -> Bool {
        resetMermaidShell()
        guard let libJS = try? String(contentsOfFile: jsPath, encoding: .utf8) else { return false }
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800),
                           configuration: WKWebViewConfiguration())
        wv.navigationDelegate = self
        mermaidWebView = wv
        mermaidShellDark = dark
        let loaded = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let latch = OneShotResume(c)
            shellLoadLatch = latch
            wv.loadHTMLString("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body></body></html>",
                              baseURL: nil)
            // All three navigation callbacks may simply never fire (web process
            // wedged before the provisional load) — race the same deadline as a
            // render so the FIFO chain can't hang on shell construction. A late
            // didFinish after the deadline hits the already-resumed latch: no-op.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.mermaidTimeout) { latch.resume(false) }
        }
        shellLoadLatch = nil
        guard loaded,
              await evalOK(wv, libJS + "\n;0"),
              await evalOK(wv, "mermaid.initialize({startOnLoad:false, securityLevel:'strict', theme:'\(dark ? "dark" : "default")'});0")
        else {
            resetMermaidShell()
            return false
        }
        return true
    }

    /// Completion-handler evaluateJavaScript wrapped for async — the async
    /// overload traps on nil results, so scripts append ";0" and errors just
    /// report false.
    private func evalOK(_ webView: WKWebView, _ script: String) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            webView.evaluateJavaScript(script) { _, error in c.resume(returning: error == nil) }
        }
    }

    // MARK: WKNavigationDelegate (shell load)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        shellLoadLatch?.resume(true)
        shellLoadLatch = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        shellLoadLatch?.resume(false)
        shellLoadLatch = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        shellLoadLatch?.resume(false)
        shellLoadLatch = nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetMermaidShell()
        shellLoadLatch?.resume(false)
        shellLoadLatch = nil
    }

    // MARK: PlantUML (subprocess)

    private func renderPlantUML(_ req: DiagramRequest) async -> DiagramResult {
        let resolution = await Task.detached { PlantUML.resolve() }.value
        let invocation: PlantUML.Invocation
        switch resolution {
        case .missingJar: return .failure(note: "PlantUML not found — showing source")
        case .missingJava: return .failure(note: "PlantUML rendering requires Java — showing source")
        case .ok(let inv): invocation = inv
        }
        let input = DiagramSupport.wrappedPlantUML(req.source)
        let svg = await Task.detached { Self.runPlantUML(invocation, input: input) }.value
        guard let svg, svg.range(of: "<svg", options: .caseInsensitive) != nil else {
            return .failure(note: "Diagram rendering failed — showing source")
        }
        return .svg(DiagramSupport.sanitizeSVG(svg))
    }

    /// Blocking pipe run. Task.detached parks a cooperative-pool thread (not a
    /// private queue) — acceptable because the render chain is single-slot
    /// serial FIFO, so at most ONE thread is ever parked here, and the watchdog
    /// caps the park at plantumlTimeout. PlantUML emits an error-picture SVG
    /// for bad syntax (often with non-zero exit) — any stdout containing <svg
    /// is accepted and shown.
    nonisolated private static func runPlantUML(_ inv: PlantUML.Invocation, input: String) -> String? {
        let p = Process()
        switch inv {
        case .jar(let java, let jar):
            p.executableURL = URL(fileURLWithPath: java)
            p.arguments = ["-Djava.awt.headless=true", "-jar", jar, "-tsvg", "-pipe", "-charset", "UTF-8"]
        case .script(let path):
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["-tsvg", "-pipe", "-charset", "UTF-8"]
        }
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        // No stderr pipe: nobody drains it, so >64KB of JVM chatter would fill
        // the pipe buffer and wedge the child mid-write. Discard instead.
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + plantumlTimeout, execute: watchdog)
        // Write stdin OFF the read path (first stdin-writing subprocess in this
        // codebase, so spelling out the rationale): a synchronous write of
        // >64KB deadlocks against a child that stopped reading (we'd never
        // reach the stdout read that unblocks it), and the old-style
        // FileHandle.write(_:) raises an uncatchable ObjC exception on EPIPE
        // when the child died. write(contentsOf:) throws a catchable Swift
        // error (macOS 10.15.4+; target is .v13), so a dead child just means a
        // short/failed write and the read path still completes.
        DispatchQueue.global().async {
            try? stdin.fileHandleForWriting.write(contentsOf: input.data(using: .utf8) ?? Data())
            try? stdin.fileHandleForWriting.close()
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
