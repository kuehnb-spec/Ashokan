import Cocoa

enum DocumentFormat {
    case html
    case markdown
}

final class Document: NSDocument {
    var model = HTMLDocumentModel.parse(HTMLDocumentModel.untitledTemplate)
    var format: DocumentFormat = .html
    /// Authoritative source text for Markdown documents.
    var markdown = ""

    private static func isMarkdown(typeName: String, url: URL?) -> Bool {
        if typeName.lowercased().contains("markdown") { return true }
        let ext = url?.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private var documentWindowController: DocumentWindowController? {
        windowControllers.first as? DocumentWindowController
    }

    override class var autosavesInPlace: Bool { true }

    // Change tracking is manual (updateChangeCount); WYSIWYG undo lives in
    // ProseMirror and source undo in the text view, so the document-level
    // undo manager would only double-count.
    override var hasUndoManager: Bool {
        get { false }
        set { }
    }

    override func makeWindowControllers() {
        WelcomeWindowController.existing?.close()
        let wc = DocumentWindowController(document: self)
        addWindowController(wc)
    }

    // Once a document gains a file (first save), its window becomes restorable.
    override var fileURL: URL? {
        didSet {
            let restorable = fileURL != nil
            DispatchQueue.main.async { [weak self] in
                self?.windowControllers.forEach { $0.window?.isRestorable = restorable }
            }
        }
    }

    // Offer only the document's own format in save panels: data(ofType:)
    // writes by self.format, so a cross-format choice would mislabel content.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        format == .markdown ? ["net.daringfireball.markdown"] : ["public.html"]
    }

    override func data(ofType typeName: String) throws -> Data {
        let text = format == .markdown ? markdown : model.assembled()
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError)
        }
        return data
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        if Self.isMarkdown(typeName: typeName, url: fileURL) {
            format = .markdown
            markdown = text
        } else {
            format = .html
            model = HTMLDocumentModel.parse(text)
        }
        documentWindowController?.documentDidReload()
    }
}
