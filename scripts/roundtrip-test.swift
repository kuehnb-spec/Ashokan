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
<figure class="shot"><img src="pic.png" width="320" alt="A picture"><figcaption>An editable caption</figcaption></figure>
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
    ("figure keeps class", { $0.contains("<figure class=\"shot\">") }),
    ("figcaption is editable (not an island) and keeps text", { $0.contains("<figcaption>An editable caption</figcaption>") }),
    ("image keeps width and alt", { $0.contains("width=\"320\"") && $0.contains("alt=\"A picture\"") }),
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
            webView.evaluateJavaScript("window.Ashokan.loadDocument(\(json)); window.Ashokan.getBodyHTML();") { [weak self] result, error in
                if let error { fail("evaluate error: \(error)") }
                guard let output = result as? String else { fail("no output"); return }
                let htmlFailures = report(output)
                self?.runMarkdownPhase(htmlFailures: htmlFailures)
            }
        }
    }

    func runMarkdownPhase(htmlFailures: Int) {
        let markdown = "# Title\n\nSome **bold** and *italic* text with `code`.\n\n- first\n- second\n\n> a quote\n"
        let payload = try! JSONSerialization.data(
            withJSONObject: ["markdown": markdown, "isMarkdown": true]
        )
        let json = String(data: payload, encoding: .utf8)!
        webView.evaluateJavaScript(
            "window.Ashokan.loadDocument(\(json)); JSON.stringify({html: window.Ashokan.getBodyHTML(), md: window.Ashokan.getMarkdown()});"
        ) { result, error in
            if let error { fail("markdown evaluate error: \(error)") }
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let html = dict["html"], let md = dict["md"]
            else { fail("no markdown output"); return }

            var failures = htmlFailures
            let mdChecks: [(String, Bool)] = [
                ("markdown renders to h1", html.contains("<h1>Title</h1>")),
                ("markdown bold/italic/code render", html.contains("<strong>bold</strong>") && html.contains("<em>italic</em>") && html.contains("<code>code</code>")),
                ("markdown list renders", html.contains("<li>first</li>")),
                ("markdown round-trips heading", md.contains("# Title")),
                ("markdown round-trips list", md.contains("- first") || md.contains("-   first") || md.contains("*   first")),
                ("markdown round-trips bold", md.contains("**bold**")),
                ("markdown round-trips quote", md.contains("> a quote")),
            ]
            print("--- markdown phase ---")
            for (name, ok) in mdChecks {
                print("\(ok ? "PASS" : "FAIL")  \(name)")
                if !ok { failures += 1 }
            }
            if failures > 0 { print("round-tripped markdown:\n\(md)") }
            exit(failures == 0 ? 0 : 1)
        }
    }
}

func fail(_ msg: String) {
    print("FAIL: \(msg)")
    exit(1)
}

func report(_ output: String) -> Int {
    print("--- round-tripped body ---")
    print(output)
    print("--------------------------")
    var failures = 0
    for (name, check) in checks {
        let ok = check(output)
        print("\(ok ? "PASS" : "FAIL")  \(name)")
        if !ok { failures += 1 }
    }
    return failures
}

let harness = Harness()
harness.start()
RunLoop.main.run(until: Date(timeIntervalSinceNow: 15))
print("FAIL: timed out waiting for editor")
exit(1)
