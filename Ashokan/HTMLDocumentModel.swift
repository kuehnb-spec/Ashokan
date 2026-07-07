import Foundation

/// Splits an HTML file into three regions so that everything outside <body>
/// is preserved byte-for-byte, no matter what the editor does:
///
///   prelude   — everything through and including the opening <body ...> tag
///   bodyHTML  — the editable document content
///   postlude  — "</body>" through the end of the file
///
/// Files with no <body> tag (fragments) round-trip as pure body content.
struct HTMLDocumentModel {
    var prelude: String
    var bodyHTML: String
    var postlude: String
    var isFragment: Bool

    static func parse(_ text: String) -> HTMLDocumentModel {
        let pattern = "^(.*?<body[^>]*>)(.*)(</body>.*)$"
        let regex = try! NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        )
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range),
              let preludeRange = Range(m.range(at: 1), in: text),
              let bodyRange = Range(m.range(at: 2), in: text),
              let postludeRange = Range(m.range(at: 3), in: text)
        else {
            return HTMLDocumentModel(prelude: "", bodyHTML: text, postlude: "", isFragment: true)
        }
        return HTMLDocumentModel(
            prelude: String(text[preludeRange]),
            bodyHTML: String(text[bodyRange]),
            postlude: String(text[postludeRange]),
            isFragment: false
        )
    }

    func assembled() -> String {
        isFragment ? bodyHTML : prelude + bodyHTML + postlude
    }

    /// The document's own <style> blocks and stylesheet <link>s from the head,
    /// injected into the editor page so the document looks like itself.
    var headStyleHTML: String {
        var pieces: [String] = []
        pieces.append(contentsOf: Self.matches("<style\\b[^>]*>.*?</style>", in: prelude))
        for link in Self.matches("<link\\b[^>]*>", in: prelude) {
            if link.range(of: "stylesheet", options: .caseInsensitive) != nil {
                pieces.append(link)
            }
        }
        return pieces.joined(separator: "\n")
    }

    /// True when the document brings any styling of its own; if not, the
    /// editor applies a clean default theme.
    var hasOwnStyles: Bool {
        if !headStyleHTML.isEmpty { return true }
        return bodyHTML.range(of: "<style", options: .caseInsensitive) != nil
    }

    /// Attributes of the original <body> tag, re-applied to the editor page body.
    var bodyAttributes: [String: String] {
        guard !isFragment,
              let tag = Self.matches("<body[^>]*>", in: prelude).last else { return [:] }
        var attrs: [String: String] = [:]
        let attrPattern = "([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>\"']+))"
        let regex = try! NSRegularExpression(pattern: attrPattern)
        let range = NSRange(tag.startIndex..., in: tag)
        for m in regex.matches(in: tag, options: [], range: range) {
            guard let nameRange = Range(m.range(at: 1), in: tag) else { continue }
            let name = String(tag[nameRange]).lowercased()
            if name == "body" { continue }
            for group in [3, 4, 5] {
                if let valueRange = Range(m.range(at: group), in: tag) {
                    attrs[name] = String(tag[valueRange])
                    break
                }
            }
        }
        return attrs
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static let untitledTemplate = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Untitled</title>
    <style>
      body {
        font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
        color: #1a1d23;
        max-width: 44em;
        margin: 0 auto;
        padding: 48px 56px 120px;
      }
      h1 { font-size: 1.9em; letter-spacing: -0.015em; margin: 1.2em 0 0.5em; }
      h2 { font-size: 1.4em; letter-spacing: -0.01em; margin: 1.4em 0 0.5em; }
      h3 { font-size: 1.15em; margin: 1.4em 0 0.4em; }
      blockquote { margin: 1em 0; padding: 0.1em 1.2em; border-left: 3px solid #d0d5dd; color: #5b6472; }
      pre { background: #f4f5f7; border: 1px solid #e4e7ec; border-radius: 8px; padding: 12px 16px; font: 13px/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
      code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; background: #f4f5f7; border-radius: 4px; padding: 0.1em 0.35em; }
      pre code { background: none; padding: 0; }
      table { border-collapse: collapse; }
      th, td { border: 1px solid #d0d5dd; padding: 6px 12px; text-align: left; }
      th { background: #f4f5f7; }
      a { color: #1f6feb; }
      hr { border: none; border-top: 1px solid #e4e7ec; margin: 2em 0; }
    </style>
    </head>
    <body>
    <h1>Untitled</h1>
    <p></p>
    </body>
    </html>
    """
}
