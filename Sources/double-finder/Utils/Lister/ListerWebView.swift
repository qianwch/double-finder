import AppKit
import WebKit

/// Thin WKWebView wrapper for rendered markdown (design §4.3). Links open in
/// the system browser; anchor jumps stay internal; a crashed web content
/// process reloads once, then falls back to source mode via onGiveUp.
@MainActor
final class ListerWebView: NSView, WKNavigationDelegate {
    var onGiveUp: (() -> Void)?          // second crash → controller falls to text mode

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
        webView = WKWebView(frame: .zero, configuration: conf)
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.frame = bounds
        addSubview(webView)
    }
    required init?(coder: NSCoder) { fatalError() }

    func loadHTML(_ html: String) {
        lastHTML = html
        crashedOnce = false
        webView.loadHTMLString(html, baseURL: nil)   // images are inlined data URIs
    }

    func teardown() {                                 // windowWillClose (design §4.1)
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
        onGiveUp = nil
    }

    func focus() { window?.makeFirstResponder(webView) }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated {
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
        webView.loadHTMLString(lastHTML, baseURL: nil)
    }
}
