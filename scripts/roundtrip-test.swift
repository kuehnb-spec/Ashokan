// Headless round-trip test for the Ashokan editing core.
// Loads editor.html + editor.js in an offscreen WKWebView, feeds it a body,
// reads it back, and checks the fidelity invariants that define the project:
// attributes survive, unknown elements survive verbatim, structure stays sane.
//
// Run: swift scripts/roundtrip-test.swift

import WebKit

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("Ashokan/Resources")

let template = try! String(contentsOf: resources.appendingPathComponent("editor.html"), encoding: .utf8)
let js = try! String(contentsOf: resources.appendingPathComponent("editor.js"), encoding: .utf8)
let page = template.replacingOccurrences(of: "__ASHOKAN_EDITOR_JS__", with: js)

let inputBody = """
<h1 class="doc-title" id="top">Hello</h1>
<p class="meta" style="color: red;">Styled <strong>bold</strong> and <span class="hl">a styled span</span>.</p>
<ul>
<li>plain list item</li>
<li>another</li>
</ul>
<table class="grid">
<thead><tr><th>A</th><th>B</th></tr></thead>
<tbody><tr><td>1</td><td>2</td></tr></tbody>
</table>
<pre><code class="language-swift">let x = 1
let y = 2</code></pre>
<div class="callout" data-kind="warn"><p>Known container with attributes.</p></div>
<details open><summary>Unknown island</summary><p>Must survive verbatim.</p></details>
<p>Inline unknown: <ruby>漢<rt>kan</rt></ruby> stays.</p>
"""

var checks: [(String, (String) -> Bool)] = [
    ("h1 keeps class+id", { $0.contains("class=\"doc-title\"") && $0.contains("id=\"top\"") }),
    ("p keeps class and inline style", { $0.contains("class=\"meta\"") && $0.contains("color: red") }),
    ("span keeps class", { $0.contains("<span class=\"hl\">") }),
    ("li not wrapped in <p>", { $0.contains("<li>plain list item</li>") }),
    ("table keeps class", { $0.contains("<table class=\"grid\"") }),
    ("thead reconstructed", { $0.contains("<thead>") && $0.contains("<tbody>") }),
    ("code block keeps language class", { $0.contains("language-swift") }),
    ("code block keeps newlines", { $0.contains("let x = 1\nlet y = 2") }),
    ("container div keeps data attribute", { $0.contains("data-kind=\"warn\"") }),
    // Boolean attrs normalize to open="" — spec-equivalent, DOM-serialization-exact.
    ("details island survives", { $0.contains("<details open=\"\"><summary>Unknown island</summary><p>Must survive verbatim.</p></details>") }),
    ("inline ruby island survives", { $0.contains("<ruby>漢<rt>kan</rt></ruby>") }),
]

final class Harness: NSObject, WKScriptMessageHandler {
    var webView: WKWebView!
    var loaded = false

    func start() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "ashokan")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.loadHTMLString(page, baseURL: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else { return }
        if type == "ready" && !loaded {
            loaded = true
            let payload = try! JSONSerialization.data(
                withJSONObject: ["bodyHTML": inputBody, "headHTML": "", "bodyAttrs": [:], "hasOwnStyles": true]
            )
            let json = String(data: payload, encoding: .utf8)!
            webView.evaluateJavaScript("window.Ashokan.loadDocument(\(json)); window.Ashokan.getBodyHTML();") { result, error in
                if let error { fail("evaluate error: \(error)") }
                guard let output = result as? String else { fail("no output"); return }
                report(output)
            }
        }
    }
}

func fail(_ msg: String) {
    print("FAIL: \(msg)")
    exit(1)
}

func report(_ output: String) {
    print("--- round-tripped body ---")
    print(output)
    print("--------------------------")
    var failures = 0
    for (name, check) in checks {
        let ok = check(output)
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        if !ok { failures += 1 }
    }
    exit(failures == 0 ? 0 : 1)
}

let harness = Harness()
harness.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 15))
print("FAIL: timed out waiting for editor")
exit(1)
