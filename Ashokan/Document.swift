import Cocoa

final class Document: NSDocument {
    var model = HTMLDocumentModel.parse(HTMLDocumentModel.untitledTemplate)

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
        let wc = DocumentWindowController(document: self)
        addWindowController(wc)
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = model.assembled().data(using: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError)
        }
        return data
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        model = HTMLDocumentModel.parse(text)
        documentWindowController?.documentDidReload()
    }
}
