@preconcurrency
import WebKit
import UIKit

/**
 MarkdownView for iOS

 - Note: Uses the classic JavaScript snippet explained in
   https://stackoverflow.com/questions/1145850/how-to-get-height-of-entire-document-with-javascript
   to determine the full document height.
 */

// MARK: - MarkdownView
open class MarkdownView: UIView {

    // MARK: - Public properties
    /// Enables or disables scrolling inside the WKWebView (default = `true`)
    @objc public var isScrollEnabled: Bool = true {
        didSet { webView?.scrollView.isScrollEnabled = isScrollEnabled }
    }

    /// Called every time a link is tapped.
    /// Implementers should handle the URL themselves.
    /// If the closure is `nil`, MarkdownView opens the link in Safari.
    @objc public var onLinkActivated: ((URL) -> Void)?

    /// Called exactly once after the first markdown layout OR
    /// every time content height changes (for example, after a `<details>` toggle).
    @objc public var onRendered: ((CGFloat) -> Void)?

    // MARK: - Private properties
    private var webView: CustomWebView?
    /// Cache for the last known content height so we can compute diff on `<details>` toggle.
    private var currentHeight = 0.0

    // MARK: - Initializers
    public convenience init() { self.init(frame: .zero) }

    /// Use this initializer if you want to build-and-cache the WKWebView up-front.
    public convenience init(css: String?              = nil,
                            plugins: [String]?        = nil,
                            stylesheets: [URL]?       = nil,
                            styled: Bool              = true) {
        self.init(frame: .zero)
        prepareWebView(css: css,
                       plugins: plugins,
                       stylesheets: stylesheets,
                       markdown: nil,
                       enableImage: nil,
                       styled: styled)
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
    }

    required public init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: "updateHeight")
    }

    // MARK: - Layout
    open override var intrinsicContentSize: CGSize {
        guard let height = webView?.contentHeight, height > 0 else { return .zero }
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }
}

// MARK: - Public API
public extension MarkdownView {

    /// Create a fresh WKWebView and load markdown.
    @objc func load(markdown: String?,
                    enableImage: Bool           = true,
                    css: String?                = nil,
                    plugins: [String]?          = nil,
                    stylesheets: [URL]?         = nil,
                    styled: Bool                = true) {
        guard let markdown else { return }

        prepareWebView(css: css,
                       plugins: plugins,
                       stylesheets: stylesheets,
                       markdown: markdown,
                       enableImage: enableImage,
                       styled: styled)
    }

    /// Update markdown in the existing WKWebView *without* rebuilding CSS or plug-ins.
    func show(markdown: String) {
        guard let wv = webView else { return }
        let escaped = escape(markdown: markdown) ?? ""
        wv.evaluateJavaScript("window.showMarkdown('\(escaped)', true)") { _, err in
            if let err { print("[MarkdownView][JS] \(err)") }
        }
    }

    /// Convenience wrapper to append one line of markdown and re-measure height.
    func addLine(_ markdown: String) {
        let js = "addLine(\(markdown.debugDescription))"
        webView?.evaluateJavaScript(js)
    }

    /// Scroll to the very bottom of the document.
    func scrollToBottom() {
        webView?.evaluateJavaScript(
            "window.scrollTo(0, document.documentElement.scrollHeight);")
    }

    /// Append a *chunk* (possibly multiple lines) of markdown with back-pressure buffering.
    func appendChunk(_ markdown: String) {
        guard let wv = webView else { return }

        // Escape back-ticks, back-slashes, dollar signs and line-breaks for JS template literal.
        let escaped = markdown
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "\n", with: "\\n")

        wv.evaluateJavaScript("window.appendMarkdown(`\(escaped)`)")
    }

    /// Measure DOM height on-demand; invokes `completion` on main thread.
    func measureHTMLHeight(_ completion: @escaping (CGFloat) -> Void) {
        let js =
          "Math.max(document.documentElement.scrollHeight," +
          "document.body.scrollHeight," +
          "document.documentElement.offsetHeight," +
          "document.body.offsetHeight," +
          "document.documentElement.clientHeight," +
          "document.body.clientHeight);"

        webView?.evaluateJavaScript(js) { result, _ in
            completion(result as? CGFloat ?? 0)
        }
    }
}

// MARK: - WKNavigationDelegate & WKScriptMessageHandler
extension MarkdownView: WKNavigationDelegate, WKScriptMessageHandler {

    // Handle link taps.
    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if let handler = onLinkActivated {
            handler(url)          // Let the caller decide what to do.
        } else {
            UIApplication.shared.open(url) // Default: open in Safari.
        }
        decisionHandler(.cancel)
    }

    // Handle JavaScript callbacks (`updateHeight`, `detailsToggled`)
    public func userContentController(_ userContentController: WKUserContentController,
                                      didReceive message: WKScriptMessage) {

        if message.name == "detailsToggled",
           let dict = message.body as? [String: Any],
           let hNum = dict["contentHeight"] as? NSNumber,
           let isOpen = dict["isExpanded"] as? Bool {

            // When a <details> collapses, subtract its inner height; add it back when expanded.
            let delta = isOpen ? 0 : -hNum.doubleValue
            currentHeight += delta
            self.onRendered?(currentHeight)
            print("[MarkdownView] currentHeight: \(currentHeight)")
        }

        if message.name == "updateHeight",
           let height = message.body as? CGFloat,
           let wv = webView,
           height != wv.contentHeight {

            wv.contentHeight = height
            wv.invalidateIntrinsicContentSize()
            invalidateIntrinsicContentSize()
            currentHeight = height
            self.onRendered?(currentHeight)
        }
    }
}

// MARK: - Private helpers
private extension MarkdownView {

    /// Build or rebuild the underlying `CustomWebView`.
    func prepareWebView(css: String?,
                        plugins: [String]?,
                        stylesheets: [URL]?,
                        markdown: String?,
                        enableImage: Bool?,
                        styled: Bool) {

        // Remove the previous web view (if any).
        webView?.removeFromSuperview()

        // --- 1. UserContentController -------------------------------------------------------
        let controller = makeContentController(css: css,
                                               plugins: plugins,
                                               stylesheets: stylesheets,
                                               markdown: markdown,
                                               enableImage: enableImage)
        controller.add(self, name: "updateHeight")
        controller.add(self, name: "detailsToggled")

        // --- 2. Create WKWebView ------------------------------------------------------------
        let config = WKWebViewConfiguration()
        config.userContentController = controller

        let wv = CustomWebView(frame: bounds, configuration: config)
        wv.scrollView.isScrollEnabled = isScrollEnabled
        wv.navigationDelegate = self
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear

        // Forward content-height updates.
        wv.contentHeightUpdated = { [weak self] h in self?.onRendered?(h) }

        // Add to view hierarchy + constraints.
        addSubview(wv)
        wv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: topAnchor),
            wv.bottomAnchor.constraint(equalTo: bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        self.webView = wv

        // --- 3. Load local HTML shell -------------------------------------------------------
        let url = styled ? Self.styledHtmlUrl : Self.nonStyledHtmlUrl
        wv.load(URLRequest(url: url))
    }

    // MARK: - JavaScript helpers -------------------------------------------------------------

    /// Wrap raw CSS into a `<style>` tag.
    func styleScript(_ css: String) -> String {
        [
            "var s = document.createElement('style');",
            "s.innerHTML = `\(css)`;",
            "document.head.appendChild(s);"
        ].joined()
    }

    /// Inject external stylesheet `<link rel="stylesheet">`
    func linkScript(_ u: URL) -> String {
        [
            "var l = document.createElement('link');",
            "l.href = '\(u.absoluteURL)';",
            "l.rel = 'stylesheet';",
            "document.head.appendChild(l);"
        ].joined()
    }

    /// Wrap CommonJS-style JavaScript plug-in and call `window.usePlugin`.
    func usePluginScript(_ body: String) -> String {
        """
        var _module = {};
        var _exports = {};
        (function(module, exports) {
            \(body)
        })(_module, _exports);
        window.usePlugin(_module.exports || _exports);
        """
    }

    /// Percent-encode markdown so it can travel safely inside a string literal.
    func escape(markdown: String) -> String? {
        markdown.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    }

    /// Build the WKUserContentController with CSS, plug-ins, height observer, etc.
    func makeContentController(css: String?,
                               plugins: [String]?,
                               stylesheets: [URL]?,
                               markdown: String?,
                               enableImage: Bool?) -> WKUserContentController {

        let c = WKUserContentController()

        // (1) Inline CSS --------------------------------------------------------------------
        if let css {
            let s = WKUserScript(source: styleScript(css),
                                 injectionTime: .atDocumentEnd,
                                 forMainFrameOnly: true)
            c.addUserScript(s)
        }

        // (2) JavaScript plug-ins -----------------------------------------------------------
        plugins?.forEach {
            let s = WKUserScript(source: usePluginScript($0),
                                 injectionTime: .atDocumentEnd,
                                 forMainFrameOnly: true)
            c.addUserScript(s)
        }

        // (3) External style sheets ---------------------------------------------------------
        stylesheets?.forEach {
            let s = WKUserScript(source: linkScript($0),
                                 injectionTime: .atDocumentEnd,
                                 forMainFrameOnly: true)
            c.addUserScript(s)
        }

        // (4) Auto-height observer ----------------------------------------------------------
        let autoHeightJS = """
        // Posts scroll/offset height on load, resize and <details> toggle.
        (function () {
            function postHeight() {
                const h = document.documentElement.scrollHeight || document.body.scrollHeight;
                window.webkit.messageHandlers.updateHeight.postMessage(h);
            }
            window.addEventListener('load', postHeight);
            window.addEventListener('resize', postHeight);
            document.addEventListener('toggle', function (e) {
                if (e.target.tagName.toLowerCase() === 'details') { postHeight(); }
            }, true);
        })();
        """
        c.addUserScript(WKUserScript(source: autoHeightJS,
                                     injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true))

        // (5) <details> expand/collapse listener --------------------------------------------
        let detailsListenerJS = """
        (function () {
            const heightCache = new Map(); // id → contentHeight
            const expanded    = new Set(); // ids currently expanded

            document.addEventListener('toggle', function (e) {
                if (e.target.tagName !== 'DETAILS') return;

                const dtl      = e.target;
                const id       = dtl.id || (dtl.id = 'dtl_' + Math.random().toString(36).slice(2));
                const isOpen   = dtl.open;  // State after toggle
                const summaryH = dtl.querySelector('summary')?.offsetHeight || 0;

                // Measure content height once, the first time the <details> is opened.
                if (isOpen && !heightCache.has(id)) {
                    const contentH = dtl.scrollHeight - summaryH;
                    heightCache.set(id, contentH);
                }

                isOpen ? expanded.add(id) : expanded.delete(id);

                window.webkit.messageHandlers.detailsToggled.postMessage({
                    detailsId:     id,
                    isExpanded:    isOpen,
                    contentHeight: heightCache.get(id) || 0
                });
            }, true);
        })();
        """
        c.addUserScript(WKUserScript(source: detailsListenerJS,
                                     injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true))

        // (6) addLine(markdownText) ---------------------------------------------------------
        let addLineJS = """
        function addLine(markdownText) {
            /* Step 1 — Markdown → HTML */
            const html = typeof marked === 'function'
                       ? marked.parse(markdownText)
                       : (window.md ? md.render(markdownText) : markdownText);

            /* Step 2 — Insert HTML into the right container */
            const wrapper = document.createElement('div');
            wrapper.innerHTML = html;
            const target = document.getElementById('content')
                       || document.querySelector('.markdown-body')
                       || document.body;
            target.appendChild(wrapper);

            /* Step 3 — Scroll to bottom & notify native code */
            const h = document.documentElement.scrollHeight || document.body.scrollHeight;
            window.webkit.messageHandlers.updateHeight.postMessage(h);
        }
        """
        c.addUserScript(WKUserScript(source: addLineJS,
                                     injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true))

        // (7) appendMarkdown(chunk) with 40 ms debounce -------------------------------------
        let appendMarkdownJS = """
        /**
         * Buffers incoming markdown chunks and renders only
         * after we detect a line break + debounce (40 ms).
         */
        window.appendMarkdown = (function () {
            let buffer  = '';
            let timerId = null;
            const WAIT  = 40; // ms

            function flush() {
                timerId = null;

                if (typeof window.showMarkdown !== 'function') {
                    // Not ready yet; try again shortly.
                    setTimeout(flush, 30);
                    return;
                }

                const encoded = encodeURIComponent(buffer);
                window.showMarkdown(encoded, true); // true = append

                requestAnimationFrame(() => {
                    const h = document.documentElement.scrollHeight || document.body.scrollHeight;
                    window.scrollTo(0, h);
                    window.webkit.messageHandlers.updateHeight.postMessage(h);
                });
            }

            return function (chunk) {
                buffer += chunk;
                if (/\\r?\\n/.test(chunk)) {
                    if (timerId) clearTimeout(timerId);
                    timerId = setTimeout(flush, WAIT);
                }
            };
        })();
        """
        c.addUserScript(WKUserScript(source: appendMarkdownJS,
                                     injectionTime: .atDocumentEnd,
                                     forMainFrameOnly: true))

        // (8) Initial markdown injection ----------------------------------------------------
        if let markdown {
            let escaped = escape(markdown: markdown) ?? ""
            let imgOpt  = (enableImage ?? true) ? "true" : "false"
            let script  = "window.showMarkdown('\(escaped)', \(imgOpt));"
            c.addUserScript(WKUserScript(source: script,
                                         injectionTime: .atDocumentEnd,
                                         forMainFrameOnly: true))
        }

        return c
    }

    // MARK: - Local HTML bundle -------------------------------------------------------------

    /// styled.html : GitHub-flavored markdown, Prism, Bootstrap, etc.
    static var styledHtmlUrl: URL = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: MarkdownView.self)
        #endif
        return bundle.url(forResource: "styled", withExtension: "html")
            ?? bundle.url(forResource: "styled",
                          withExtension: "html",
                          subdirectory: "MarkdownView.bundle")!
    }()

    /// non_styled.html : minimal HTML shell without CSS.
    static var nonStyledHtmlUrl: URL = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: MarkdownView.self)
        #endif
        return bundle.url(forResource: "non_styled", withExtension: "html")
            ?? bundle.url(forResource: "non_styled",
                          withExtension: "html",
                          subdirectory: "MarkdownView.bundle")!
    }()
}

// MARK: - CustomWebView --------------------------------------------------------------------

private class CustomWebView: WKWebView {

    /// The last measured content height from JavaScript.
    var contentHeight: CGFloat = 0 {
        didSet {
            guard contentHeight != 0, contentHeight != oldValue else { return }
            contentHeightUpdated?(contentHeight)
        }
    }

    /// Called whenever `contentHeight` changes.
    var contentHeightUpdated: ((CGFloat) -> Void)?

    /// Enables autolayout to size the web view by content height.
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: contentHeight)
    }
}
