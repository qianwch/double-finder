import AppKit
import WebKit

/// Thin WKWebView wrapper for rendered markdown (design §4.3). Links open in
/// the system browser; anchor jumps stay internal; a crashed web content
/// process reloads once, then falls back to source mode via onGiveUp.
@MainActor
final class ListerWebView: NSView, WKNavigationDelegate {
    var onGiveUp: (() -> Void)?          // second crash → controller falls to text mode

    /// Mermaid themes are BAKED into the rendered SVG (unlike the page CSS,
    /// which adapts via prefers-color-scheme) — the controller re-renders
    /// diagrams on a live light/dark switch.
    var onAppearanceChanged: (() -> Void)?

    private let webView: WKWebView
    private var lastHTML = ""
    private var crashedOnce = false

    override init(frame: NSRect) {
        let conf = WKWebViewConfiguration()
        // Defense in depth: this renderer only ever shows our own escaped HTML
        // (never scripts) and exists solely to view UNTRUSTED files — so disable
        // JavaScript outright. Belt-and-suspenders against any future escaping
        // regression; the render path never needs JS.
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = false
        conf.defaultWebpagePreferences = prefs
        // Own the private page scheme: with a handler registered WebKit
        // answers every `x-double-finder-lister://` request itself (empty)
        // instead of handing an unknown scheme to LaunchServices, which pops
        // the system "no application set to open URL" dialog.
        conf.setURLSchemeHandler(EmptySchemeHandler(), forURLScheme: Self.pageBase.scheme!)
        webView = WKWebView(frame: .zero, configuration: conf)
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Base URL of every rendered page. A private scheme (never http/https, so
    /// relative links can never resolve to something the delegate would hand to
    /// the system browser) and a stable document URL, which is what makes
    /// `#anchor` clicks same-document navigations (ebook TOC / footnotes) —
    /// with a nil base the page is about:blank and fragment jumps are ignored.
    static let pageBase = URL(string: "x-double-finder-lister://document/")!

    func loadHTML(_ html: String) {
        lastHTML = html
        crashedOnce = false
        // The empty page (clearing / teardown) goes to about:blank: loading ""
        // against the private base made WebKit navigate to the base URL itself.
        webView.loadHTMLString(html, baseURL: html.isEmpty ? nil : Self.pageBase)   // images are inlined data URIs
    }

    func teardown() {                                 // windowWillClose (design §4.1)
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        onGiveUp = nil
        onAppearanceChanged = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChanged?()
    }

    /// ⌘=/⌘-/⌘0 zoom of the rendered page (persists across loadHTML calls —
    /// pageZoom is a WKWebView property, not per-document).
    func setZoom(_ zoom: CGFloat) { webView.pageZoom = zoom }

    func focus() { window?.makeFirstResponder(webView) }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
            // In-page `#anchor` jumps (ebook table of contents / footnotes) resolve
            // against `pageBase` — same document, just a fragment: let them through.
            if let url = navigationAction.request.url, url.scheme == Self.pageBase.scheme,
               url.fragment != nil {
                decisionHandler(.allow)
                return
            }
            // The converter only HTML-escapes hrefs, so `[x](javascript:alert(1))`
            // would produce a clickable link — allow only http/https to the system
            // browser and drop every other scheme (javascript:/file:/data: etc.).
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)   // linkActivated never navigates inside the webview
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if crashedOnce { onGiveUp?(); return }
        crashedOnce = true
        webView.loadHTMLString(lastHTML, baseURL: lastHTML.isEmpty ? nil : Self.pageBase)
    }
}

/// Answers every request on the private page scheme with an empty 404-style
/// response. Nothing legitimate ever fetches from it (all resources are inlined
/// data URIs); registering it only keeps the scheme out of LaunchServices.
private final class EmptySchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url ?? ListerWebView.pageBase
        task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
