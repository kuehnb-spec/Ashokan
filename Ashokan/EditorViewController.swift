import Cocoa
import WebKit

/// Breaks the WKUserContentController → handler retain cycle so closed
/// documents can deallocate their web views.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?
    init(_ delegate: WKScriptMessageHandler) { self.delegate = delegate }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(ucc, didReceive: message)
    }
}

/// The WYSIWYG pane: a WKWebView (Apple's system HTML engine) hosting the
/// bundled ProseMirror editing core.
final class EditorViewController: NSViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var webView: WKWebView!
    private var shellLoaded = false
    private var pendingLoad: (() -> Void)?

    /// (bodyHTML, markdown-if-markdown-doc, wordCount)
    var onDocChanged: ((String, String?, Int) -> Void)?
    var onStats: ((Int) -> Void)?
    /// (pending tracked changes, comments)
    var onReviewCounts: ((Int, Int) -> Void)?
    /// (text, author, rect of the clicked comment in view coordinates)
    var onCommentClicked: ((String, String, NSRect) -> Void)?
    /// A margin card asked for the comment-edit dialog (selection already set).
    var onEditCommentRequested: (() -> Void)?

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakScriptMessageHandler(self), name: "ashokan")
        // Allow the document's relative images/stylesheets (file URLs next to
        // the document) to load inside the editor page.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        view = webView
    }

    /// Loads the editor shell page with the bundled JS inlined, based at the
    /// document's folder so relative resources resolve.
    func loadShell(baseURL: URL?) {
        guard
            let htmlURL = Bundle.main.url(forResource: "editor", withExtension: "html"),
            let jsURL = Bundle.main.url(forResource: "editor", withExtension: "js"),
            let template = try? String(contentsOf: htmlURL, encoding: .utf8),
            let js = try? String(contentsOf: jsURL, encoding: .utf8)
        else {
            NSLog("Ashokan: editor resources missing from bundle")
            return
        }
        shellLoaded = false
        let page = template.replacingOccurrences(of: "__ASHOKAN_EDITOR_JS__", with: js)
        webView.loadHTMLString(page, baseURL: baseURL)
    }

    func loadDocument(_ model: HTMLDocumentModel) {
        load(payload: [
            "bodyHTML": model.bodyHTML,
            "headHTML": model.headStyleHTML,
            "bodyAttrs": model.bodyAttributes,
            "hasOwnStyles": model.hasOwnStyles,
        ])
    }

    func loadMarkdownDocument(_ markdown: String) {
        load(payload: ["markdown": markdown, "isMarkdown": true])
    }

    private func load(payload: [String: Any]) {
        var payload = payload
        payload["author"] = NSFullUserName()
        let work = { [weak self] in
            guard let self, let json = Self.jsonString(payload) else { return }
            self.webView.evaluateJavaScript("window.Ashokan.loadDocument(\(json));")
        }
        if shellLoaded { work() } else { pendingLoad = work }
    }

    /// Invokes a function on the JS-side `window.Ashokan` API.
    func call(_ function: String, argument: Any? = nil) {
        var argJS = ""
        if let argument, let json = Self.jsonString(argument) {
            argJS = json
        }
        webView.evaluateJavaScript("window.Ashokan.\(function)(\(argJS));")
    }

    func focusEditor() {
        view.window?.makeFirstResponder(webView)
        call("focus")
    }

    /// Paginated PDF export through the native print pipeline, so the
    /// editor page's @media print rules (keep images/tables whole, keep
    /// headings with their text) apply.
    func exportPDF(to url: URL) {
        let printInfo = NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.topMargin = 54
        printInfo.bottomMargin = 54
        printInfo.leftMargin = 54
        printInfo.rightMargin = 54
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = true
        // WKWebView's print view starts zero-sized; give it the page rect.
        operation.view?.frame = NSRect(origin: .zero, size: printInfo.paperSize)
        if let window = view.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private static func jsonString(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.fragmentsAllowed]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        switch type {
        case "ready":
            shellLoaded = true
            pendingLoad?()
            pendingLoad = nil
        case "docChanged":
            if let html = dict["bodyHTML"] as? String {
                onDocChanged?(html, dict["markdown"] as? String, dict["words"] as? Int ?? 0)
            }
            onReviewCounts?(dict["changes"] as? Int ?? 0, dict["comments"] as? Int ?? 0)
        case "commentClicked":
            if let text = dict["text"] as? String {
                let left = dict["left"] as? Double ?? 0
                let top = dict["top"] as? Double ?? 0
                let bottom = dict["bottom"] as? Double ?? 0
                // WKWebView is flipped, so JS client coords map directly.
                let rect = NSRect(x: left, y: top, width: 2, height: max(2, bottom - top))
                onCommentClicked?(text, dict["author"] as? String ?? "", rect)
            }
        case "editCommentRequest":
            onEditCommentRequested?()
        case "stats":
            if let words = dict["words"] as? Int {
                onStats?(words)
            }
            onReviewCounts?(dict["changes"] as? Int ?? 0, dict["comments"] as? Int ?? 0)
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Clicked links open in the default browser; the editor never navigates away.
        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
