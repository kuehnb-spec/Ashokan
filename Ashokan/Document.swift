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

    /// MCP: stable id and optimistic-concurrency revision. The revision
    /// bump is one integer increment on the existing change path — the
    /// only cost the MCP feature adds to normal editing.
    let mcpId = String(UUID().uuidString.prefix(8)).lowercased()
    private(set) var revision = 1
    func bumpRevision() { revision += 1 }

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

    // MARK: - External changes (the two-writers feature: an agent rewrites
    // the file on disk while it's open here)

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in
            self?.handleExternalChange()
        }
    }

    private func handleExternalChange() {
        guard let url = fileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let diskDate = attrs[.modificationDate] as? Date,
              let knownDate = fileModificationDate,
              diskDate.timeIntervalSince(knownDate) > 0.1 else { return }

        if isDocumentEdited {
            presentExternalChangeConflict(url: url, diskDate: diskDate)
        } else {
            reloadFromDisk(url: url)
            documentWindowController?.flashStatus("Reloaded — file was changed on disk by another program")
        }
    }

    private func reloadFromDisk(url: URL) {
        try? revert(toContentsOf: url, ofType: fileType ?? "public.html")
    }

    private func presentExternalChangeConflict(url: URL, diskDate: Date) {
        guard let window = documentWindowController?.window else {
            // No UI to ask; keep the in-memory version and note the new date
            // so we don't loop.
            fileModificationDate = diskDate
            return
        }
        let alert = NSAlert()
        alert.messageText = "File Changed on Disk"
        alert.informativeText = "\(displayName ?? "This document") was modified by another program (probably an agent), but you also have unsaved edits here. Which version do you want?"
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Keep My Version")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.reloadFromDisk(url: url)
                self.documentWindowController?.flashStatus("Reloaded from disk — your unsaved edits were discarded")
            } else {
                // Keep ours; adopt the disk date so this exact change stops
                // re-prompting. Saving will overwrite the external version.
                self.fileModificationDate = diskDate
                self.documentWindowController?.flashStatus("Keeping your version — saving will overwrite the on-disk change")
            }
        }
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
