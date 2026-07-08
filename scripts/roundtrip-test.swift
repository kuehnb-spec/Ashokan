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
            self.runReviewPhase(previousFailures: failures)
        }
    }

    func runReviewPhase(previousFailures: Int) {
        let reviewBody = #"<p>Keep <del data-ashokan-author="Agent">old</del><ins data-ashokan-author="Agent">new</ins> text with <mark title="check this" data-ashokan-author="Brant">a note</mark>.</p>"#
        let payload = try! JSONSerialization.data(
            withJSONObject: ["bodyHTML": reviewBody, "headHTML": "", "bodyAttrs": [:], "hasOwnStyles": true]
        )
        let json = String(data: payload, encoding: .utf8)!
        let script = """
        (() => {
          const out = {}
          window.Ashokan.loadDocument(\(json))
          out.roundtrip = window.Ashokan.getBodyHTML()
          window.Ashokan.acceptAllChanges()
          out.accepted = window.Ashokan.getBodyHTML()
          window.Ashokan.loadDocument(\(json))
          window.Ashokan.rejectAllChanges()
          out.rejected = window.Ashokan.getBodyHTML()
          return JSON.stringify(out)
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            if let error { fail("review evaluate error: \(error)") }
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let roundtrip = dict["roundtrip"], let accepted = dict["accepted"], let rejected = dict["rejected"]
            else { fail("no review output"); return }

            var failures = previousFailures
            let checks: [(String, Bool)] = [
                ("ins/del/comment markup round-trips with authors",
                 roundtrip.contains("<del data-ashokan-author=\"Agent\">old</del>")
                 && roundtrip.contains("<ins data-ashokan-author=\"Agent\">new</ins>")
                 && roundtrip.contains("title=\"check this\"")),
                ("accept all: deletion removed, insertion kept unwrapped",
                 accepted.contains("Keep new text") && !accepted.contains("<ins") && !accepted.contains("old")),
                ("accept all: comment untouched", accepted.contains("<mark")),
                ("reject all: insertion removed, deletion restored unwrapped",
                 rejected.contains("Keep old text") && !rejected.contains("<del") && !rejected.contains("new")),
            ]
            print("--- review phase ---")
            for (name, ok) in checks {
                print("\(ok ? "PASS" : "FAIL")  \(name)")
                if !ok { failures += 1 }
            }
            if failures > previousFailures {
                print("roundtrip: \(roundtrip)\naccepted: \(accepted)\nrejected: \(rejected)")
            }
            self.runAgentPhase(previousFailures: failures)
        }
    }

    func runAgentPhase(previousFailures: Int) {
        let body = #"<!-- ashokan-agent-instructions: be kind --><p>The quick brown fox jumps over the lazy dog near the river bank.</p>"#
        let payload = try! JSONSerialization.data(
            withJSONObject: ["bodyHTML": body, "headHTML": "", "bodyAttrs": [:], "hasOwnStyles": true]
        )
        let json = String(data: payload, encoding: .utf8)!
        let edits = #"[{"quote": "quick brown fox", "replacement": "swift auburn fox", "comment": "more precise"}, {"quote": "lazy dog", "comment": "is the dog really lazy?"}, {"quote": "text that does not exist", "replacement": "x"}]"#
        let script = """
        (() => {
          const out = {}
          window.Ashokan.loadDocument(\(json))
          out.result = window.Ashokan.applyAgentEdits(\(edits), "TestModel")
          out.html = window.Ashokan.getBodyHTML()
          return JSON.stringify(out)
        })()
        """
        webView.evaluateJavaScript(script) { result, error in
            if let error { fail("agent evaluate error: \(error)") }
            guard let raw = result as? String,
                  let data = raw.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let html = dict["html"] as? String,
                  let applyResult = dict["result"] as? [String: Any]
            else { fail("no agent output"); return }

            var failures = previousFailures
            let applied = applyResult["applied"] as? Int ?? -1
            let failedCount = (applyResult["failed"] as? [Any])?.count ?? -1
            let checks: [(String, Bool)] = [
                ("HTML comment survives round-trip", html.contains("<!-- ashokan-agent-instructions: be kind -->")),
                ("agent replacement applied as del+ins with author",
                 html.contains(#"data-ashokan-author="TestModel""#)
                 && html.range(of: #"<del [^>]*>.*quick brown fox.*</del>"#, options: .regularExpression) != nil
                 && html.contains(">swift auburn fox</ins>")),
                ("agent comment applied as mark with title",
                 html.contains(#"title="is the dog really lazy?""#)),
                ("unmatched quote reported, not applied", applied == 2 && failedCount == 1),
            ]
            print("--- agent phase ---")
            for (name, ok) in checks {
                print("\(ok ? "PASS" : "FAIL")  \(name)")
                if !ok { failures += 1 }
            }
            if failures > previousFailures { print("html: \(html)\nresult: \(applyResult)") }
            self.runCorpusPhase(previousFailures: failures)
        }
    }

    // Adversarial fixtures: the nastiest agent-generated markup we can
    // think of must survive a load+serialize round-trip.
    func runCorpusPhase(previousFailures: Int) {
        let script = "<script>if (a < b && c > d) { emit(\"<tag>\"); }</script>"
        let corpus = #"<p>Entities: &amp; &lt; &gt; stay escaped.</p>"#
            + script
            + #"<style>.x > .y::before { content: "<>"; }</style>"#
            + #"<svg viewBox="0 0 10 10"><circle cx="5" cy="5" r="4" fill="red"/></svg>"#
            + #"<my-widget config='{"a": 1}'><inner-part>opaque</inner-part></my-widget>"#
            + #"<ul><li><input type="checkbox" checked disabled> done task</li><li><input type="checkbox"> open task</li></ul>"#
            + #"<form action="/x"><label>Name <input type="text" name="n"></label></form>"#
            + #"<table class="wide"><tbody><tr><td>r1c1</td><td>r1c2</td><td>r1c3</td></tr><tr><td>r2c1</td><td>r2c2</td><td>r2c3</td></tr><tr><td>r3c1</td><td>r3c2</td><td>r3c3</td></tr></tbody></table>"#
        let payload = try! JSONSerialization.data(
            withJSONObject: ["bodyHTML": corpus, "headHTML": "", "bodyAttrs": [:], "hasOwnStyles": true]
        )
        let json = String(data: payload, encoding: .utf8)!
        webView.evaluateJavaScript("window.Ashokan.loadDocument(\(json)); window.Ashokan.getBodyHTML()") { result, error in
            if let error { fail("corpus evaluate error: \(error)") }
            guard let html = result as? String else { fail("no corpus output"); return }
            var failures = previousFailures
            let checks: [(String, Bool)] = [
                ("entities stay escaped", html.contains("&amp; &lt; &gt;")),
                ("script island survives with raw <  > inside",
                 html.contains(#"if (a < b && c > d) { emit("<tag>"); }"#)),
                ("style island survives with selector combinators",
                 html.contains(#".x > .y::before"#)),
                ("svg island survives", html.contains(#"<circle cx="5" cy="5" r="4" fill="red">"#)
                                     || html.contains(#"<circle cx="5" cy="5" r="4" fill="red"/>"#)
                                     || html.contains(#"<circle cx="5" cy="5" r="4" fill="red"></circle>"#)),
                ("custom element tree survives with JSON attribute",
                 html.contains("<inner-part>opaque</inner-part>")
                 && (html.contains(#"{"a": 1}"#) || html.contains("{&quot;a&quot;: 1}"))),
                ("checked task checkbox round-trips",
                 html.range(of: #"<input [^>]*type="checkbox"[^>]*checked"#, options: .regularExpression) != nil
                 || html.range(of: #"<input [^>]*checked[^>]*type="checkbox""#, options: .regularExpression) != nil),
                ("unchecked task checkbox has no checked attr",
                 html.contains("open task") && {
                     let parts = html.components(separatedBy: "open task")
                     return parts.first?.components(separatedBy: "<input").last?.contains("checked") == false
                 }()),
                ("form island survives", html.contains(#"<form action="/x">"#) && html.contains(#"name="n""#)),
                ("table keeps all 9 cells", (1...3).allSatisfy { r in (1...3).allSatisfy { c in html.contains("r\(r)c\(c)") } }),
            ]
            print("--- corpus phase ---")
            for (name, ok) in checks {
                print("\(ok ? "PASS" : "FAIL")  \(name)")
                if !ok { failures += 1 }
            }
            if failures > previousFailures { print("corpus html: \(html)") }
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
