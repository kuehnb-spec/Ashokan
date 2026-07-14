import Cocoa
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    let editorVC = EditorViewController()
    let sourceVC = SourceViewController()
    private let splitVC = NSSplitViewController()
    private var sourceItem: NSSplitViewItem!
    private var stylePopup: NSPopUpButton!
    private var statusPathLabel: NSTextField!
    private var statusInfoLabel: NSTextField!
    private var lastWordCount = 0
    private var pendingChanges = 0
    private var pendingComments = 0
    private var suggesting = false
    private var suggestButton: NSButton!
    private var reviewAccessory: NSTitlebarAccessoryViewController!
    private var showingCommentsMargin = false
    private var showCommentsButton: NSButton!
    private var acceptMenuButton: NSPopUpButton!
    private var rejectMenuButton: NSPopUpButton!
    private var previewControl: NSSegmentedControl!
    private var changeAuthors: [String] = []
    private var statusFlashUntil = Date.distantPast

    private var doc: Document { document as! Document }

    convenience init(document: Document) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.minSize = NSSize(width: 480, height: 300)
        self.init(window: window)
        // NOTE: never assign self.document here — NSDocument.addWindowController
        // skips (and never retains) a controller whose document is already set,
        // and the whole window silently deallocates.

        let editorItem = NSSplitViewItem(viewController: editorVC)
        editorItem.minimumThickness = 320

        sourceItem = NSSplitViewItem(viewController: sourceVC)
        sourceItem.minimumThickness = 280
        sourceItem.canCollapse = true
        sourceItem.isCollapsed = true

        splitVC.addSplitViewItem(editorItem)
        splitVC.addSplitViewItem(sourceItem)

        // Content = split view over a thin status bar.
        let rootVC = NSViewController()
        rootVC.view = NSView()
        rootVC.addChild(splitVC)
        let statusBar = buildStatusBar()
        splitVC.view.translatesAutoresizingMaskIntoConstraints = false
        rootVC.view.addSubview(splitVC.view)
        rootVC.view.addSubview(statusBar)
        NSLayoutConstraint.activate([
            splitVC.view.topAnchor.constraint(equalTo: rootVC.view.topAnchor),
            splitVC.view.leadingAnchor.constraint(equalTo: rootVC.view.leadingAnchor),
            splitVC.view.trailingAnchor.constraint(equalTo: rootVC.view.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: splitVC.view.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: rootVC.view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: rootVC.view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: rootVC.view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 24),
        ])
        window.contentViewController = rootVC
        // Setting contentViewController resizes the window to the content's
        // fitting size — which is ~zero for an unconstrained split view.
        window.setContentSize(NSSize(width: 1080, height: 780))
        window.center()

        // Multiple documents open as native window tabs.
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "AshokanDocument"

        // Top tier: file-level commands. Formatting lives in the bar below.
        let toolbar = NSToolbar(identifier: "AshokanToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let formatAccessory = NSTitlebarAccessoryViewController()
        formatAccessory.layoutAttribute = .bottom
        formatAccessory.view = buildFormatBar()
        window.addTitlebarAccessoryViewController(formatAccessory)

        reviewAccessory = NSTitlebarAccessoryViewController()
        reviewAccessory.layoutAttribute = .bottom
        reviewAccessory.view = buildReviewBar()
        reviewAccessory.isHidden = true
        window.addTitlebarAccessoryViewController(reviewAccessory)

        wireUp()
    }

    // The document arrives via NSDocument.addWindowController, after init.
    private var editorLoaded = false
    override var document: AnyObject? {
        didSet {
            if document != nil && !editorLoaded {
                editorLoaded = true
                loadEditor()
            }
        }
    }

    private func wireUp() {
        editorVC.onDocChanged = { [weak self] bodyHTML, markdown, words in
            guard let self else { return }
            // Wipe guard: an empty body from a non-empty document means the
            // editor bridge misfired, not that the user deleted everything
            // (ProseMirror always serializes at least an empty paragraph).
            if bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !self.doc.model.bodyHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSLog("Ashokan: ignored suspicious empty-body update")
                return
            }
            if self.doc.format == .markdown {
                self.doc.markdown = markdown ?? self.doc.markdown
            } else {
                self.doc.model.bodyHTML = bodyHTML
            }
            self.doc.updateChangeCount(.changeDone)
            self.doc.bumpRevision()
            self.lastWordCount = words
            self.updateStatusBar()
            if !self.sourceItem.isCollapsed && !self.sourceVC.isEditing {
                self.sourceVC.setText(self.sourceText())
            }
        }
        editorVC.onReviewCounts = { [weak self] changes, comments in
            self?.pendingChanges = changes
            self?.pendingComments = comments
            self?.updateStatusBar()
            self?.updateReviewBarVisibility()
        }
        editorVC.onCommentClicked = { [weak self] text, author, rect in
            self?.showCommentPopover(text: text, author: author, at: rect)
        }
        editorVC.onEditCommentRequested = { [weak self] in
            self?.presentEditCommentDialog()
        }
        editorVC.onAuthors = { [weak self] authors in
            guard let self, authors != self.changeAuthors else { return }
            self.changeAuthors = authors
            self.rebuildBulkMenus()
        }
        editorVC.onWebProcessTerminated = { [weak self] in
            guard let self else { return }
            self.loadEditor()
            self.flashStatus("Editor recovered after a WebKit crash — content restored")
        }
        editorVC.onCursorBlock = { [weak self] block in
            guard let popup = self?.stylePopup else { return }
            switch block {
            case "h1": popup.selectItem(at: 0)
            case "h2": popup.selectItem(at: 1)
            case "h3": popup.selectItem(at: 2)
            case "code": popup.selectItem(at: 4)
            case "body": popup.selectItem(at: 3)
            default: popup.select(nil)   // h4–h6 have no popup entry
            }
        }
        editorVC.onStats = { [weak self] words in
            self?.lastWordCount = words
            self?.updateStatusBar()
        }
        sourceVC.onTextChanged = { [weak self] text in
            guard let self else { return }
            if self.doc.format == .markdown {
                self.doc.markdown = text
            } else {
                self.doc.model = HTMLDocumentModel.parse(text)
            }
            self.doc.updateChangeCount(.changeDone)
            self.pushDocumentToEditor()
        }
    }

    private func sourceText() -> String {
        doc.format == .markdown ? doc.markdown : doc.model.assembled()
    }

    private func pushDocumentToEditor() {
        if doc.format == .markdown {
            editorVC.loadMarkdownDocument(doc.markdown)
        } else {
            editorVC.loadDocument(doc.model)
        }
    }

    private func loadEditor() {
        // Untitled windows stay out of state restoration so a template-bearing
        // "Untitled" doesn't get preserved as a draft and resurrected forever.
        window?.isRestorable = doc.fileURL != nil
        editorVC.loadShell(baseURL: doc.fileURL?.deletingLastPathComponent())
        pushDocumentToEditor()
        updateStatusBar()
    }

    /// Called when the document re-reads its file (e.g. Revert to Saved).
    func documentDidReload() {
        pushDocumentToEditor()
        if !sourceItem.isCollapsed {
            sourceVC.setText(sourceText())
        }
        updateStatusBar()
    }

    // MARK: - Status bar

    private func buildStatusBar() -> NSView {
        let bar = NSBox()
        bar.boxType = .custom
        bar.borderWidth = 0
        bar.fillColor = .windowBackgroundColor
        bar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        statusPathLabel = NSTextField(labelWithString: "")
        statusPathLabel.font = .systemFont(ofSize: 11)
        statusPathLabel.textColor = .secondaryLabelColor
        statusPathLabel.lineBreakMode = .byTruncatingMiddle
        statusPathLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusInfoLabel = NSTextField(labelWithString: "")
        statusInfoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusInfoLabel.textColor = .secondaryLabelColor
        statusInfoLabel.translatesAutoresizingMaskIntoConstraints = false

        bar.contentView?.addSubview(separator)
        bar.contentView?.addSubview(statusPathLabel)
        bar.contentView?.addSubview(statusInfoLabel)
        let content = bar.contentView!
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: content.topAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusPathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            statusPathLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            statusInfoLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            statusInfoLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            statusPathLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusInfoLabel.leadingAnchor, constant: -16),
        ])
        return bar
    }

    private func updateStatusBar() {
        guard statusPathLabel != nil else { return }
        guard Date() >= statusFlashUntil else { return }
        if let url = doc.fileURL {
            statusPathLabel.stringValue = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            statusPathLabel.toolTip = url.path
        } else {
            statusPathLabel.stringValue = "Not saved yet"
            statusPathLabel.toolTip = nil
        }

        var parts: [String] = []
        parts.append(doc.format == .markdown ? "Markdown" : "HTML")
        if let url = doc.fileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            if let size = attrs[.size] as? Int {
                parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
            }
            if let modified = attrs[.modificationDate] as? Date {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                parts.append("Saved \(formatter.string(from: modified))")
            }
        }
        parts.append("\(lastWordCount) word\(lastWordCount == 1 ? "" : "s")")
        if pendingChanges > 0 {
            parts.append("\(pendingChanges) suggestion\(pendingChanges == 1 ? "" : "s")")
        }
        if pendingComments > 0 {
            parts.append("\(pendingComments) comment\(pendingComments == 1 ? "" : "s")")
        }
        statusInfoLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    // MARK: - Format actions (reached from menus and toolbar via responder chain)

    @objc func fmtBold(_ sender: Any?) { editorVC.call("bold") }
    @objc func fmtItalic(_ sender: Any?) { editorVC.call("italic") }
    @objc func fmtUnderline(_ sender: Any?) { editorVC.call("underline") }
    @objc func fmtStrike(_ sender: Any?) { editorVC.call("strike") }
    @objc func fmtInlineCode(_ sender: Any?) { editorVC.call("inlineCode") }
    @objc func fmtH1(_ sender: Any?) { editorVC.call("setHeading", argument: 1) }
    @objc func fmtH2(_ sender: Any?) { editorVC.call("setHeading", argument: 2) }
    @objc func fmtH3(_ sender: Any?) { editorVC.call("setHeading", argument: 3) }
    @objc func fmtH4(_ sender: Any?) { editorVC.call("setHeading", argument: 4) }
    @objc func fmtBody(_ sender: Any?) { editorVC.call("setParagraph") }
    @objc func fmtBulletList(_ sender: Any?) { editorVC.call("bulletList") }
    @objc func fmtOrderedList(_ sender: Any?) { editorVC.call("orderedList") }
    @objc func fmtBlockquote(_ sender: Any?) { editorVC.call("blockquote") }
    @objc func fmtCodeBlock(_ sender: Any?) { editorVC.call("toggleCodeBlock") }
    @objc func fmtHorizontalRule(_ sender: Any?) { editorVC.call("horizontalRule") }

    @objc func fmtLink(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Link the selected text to:"
        alert.addButton(withTitle: "Add Link")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let href = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !href.isEmpty else { return }
            self?.editorVC.call("setLink", argument: href)
        }
    }

    // MARK: - Insert: images and tables

    @objc func insertImage(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose an image to embed in the document"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.embedImage(from: url)
        }
    }

    private func embedImage(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let proceed = {
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            let src = "data:\(mime);base64,\(data.base64EncodedString())"
            let alt = url.deletingPathExtension().lastPathComponent
            self.editorVC.webView.evaluateJavaScript(
                "window.Ashokan.insertImage(\(Self.json(src)), \(Self.json(alt)));"
            )
        }
        if data.count > 8_000_000, let window {
            let alert = NSAlert()
            alert.messageText = "Large Image"
            alert.informativeText = "This image is \(data.count / 1_000_000) MB and will be embedded directly in the HTML file. Embed anyway?"
            alert.addButton(withTitle: "Embed")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { proceed() }
            }
        } else {
            proceed()
        }
    }

    private static func json(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])
        return String(data: data, encoding: .utf8)!
    }

    @objc func insertTable(_ sender: NSMenuItem) {
        if sender.tag > 0 {
            editorVC.webView.evaluateJavaScript(
                "window.Ashokan.insertTable(\(sender.tag / 100), \(sender.tag % 100));")
        } else {
            promptCustomTableSize()
        }
    }

    private func promptCustomTableSize() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Insert Table"
        alert.addButton(withTitle: "Insert")
        alert.addButton(withTitle: "Cancel")
        let rows = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        rows.stringValue = "3"
        let cols = NSTextField(frame: NSRect(x: 0, y: 0, width: 60, height: 24))
        cols.stringValue = "3"
        let stack = NSStackView(views: [NSTextField(labelWithString: "Rows:"), rows,
                                        NSTextField(labelWithString: "Columns:"), cols])
        stack.orientation = .horizontal
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = rows
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let r = max(2, min(50, Int(rows.stringValue) ?? 3))
            let c = max(1, min(20, Int(cols.stringValue) ?? 3))
            self?.editorVC.webView.evaluateJavaScript("window.Ashokan.insertTable(\(r), \(c));")
        }
    }

    @objc func tableCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        editorVC.call("tableCommand", argument: name)
    }

    @objc func alignImage(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        editorVC.call("alignImage", argument: mode)
    }

    // MARK: - PDF export

    @objc func exportPDF(_ sender: Any?) {
        guard let window else { return }
        // Export-time review check: never let markup ship in a PDF unnoticed.
        if pendingChanges > 0 || pendingComments > 0 {
            let alert = NSAlert()
            alert.messageText = "Pending Review Items"
            var parts: [String] = []
            if pendingChanges > 0 { parts.append("\(pendingChanges) suggested change\(pendingChanges == 1 ? "" : "s")") }
            if pendingComments > 0 { parts.append("\(pendingComments) comment\(pendingComments == 1 ? "" : "s")") }
            alert.informativeText = "This document has \(parts.joined(separator: " and ")). The PDF will match the current preview mode (\(currentPreviewMode == "markup" ? "markup visible" : currentPreviewMode))."
            alert.addButton(withTitle: "Export as Shown")
            alert.addButton(withTitle: "Accept All & Export")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    self.presentExportPanel()
                case .alertSecondButtonReturn:
                    self.editorVC.call("acceptAllChanges")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.presentExportPanel()
                    }
                default:
                    break
                }
            }
            return
        }
        presentExportPanel()
    }

    private func presentExportPanel() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = (doc.displayName as NSString).deletingPathExtension + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.editorVC.exportPDF(to: url, title: (self.doc.displayName as NSString).deletingPathExtension)
        }
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        switch sender.indexOfSelectedItem {
        case 0: fmtH1(sender)
        case 1: fmtH2(sender)
        case 2: fmtH3(sender)
        case 3: fmtBody(sender)
        case 4: fmtCodeBlock(sender)
        default: break
        }
    }

    // MARK: - Review mode

    @objc func toggleSuggesting(_ sender: Any?) {
        suggesting.toggle()
        suggestButton?.state = suggesting ? .on : .off
        editorVC.call("setSuggesting", argument: suggesting)
        updateReviewBarVisibility()
        editorVC.focusEditor()
    }

    @objc func reviewNextChange(_ sender: Any?) { editorVC.call("nextChange") }
    @objc func reviewPreviousChange(_ sender: Any?) { editorVC.call("previousChange") }
    @objc func reviewAcceptChange(_ sender: Any?) { editorVC.call("acceptChange") }
    @objc func reviewRejectChange(_ sender: Any?) { editorVC.call("rejectChange") }
    @objc func reviewAcceptAll(_ sender: Any?) { editorVC.call("acceptAllChanges") }
    @objc func reviewRejectAll(_ sender: Any?) { editorVC.call("rejectAllChanges") }
    @objc func reviewNextComment(_ sender: Any?) { editorVC.call("nextComment") }
    @objc func reviewPreviousComment(_ sender: Any?) { editorVC.call("previousComment") }
    @objc func reviewRemoveComment(_ sender: Any?) { editorVC.call("removeComment") }

    @objc func reviewAddComment(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Comment"
        alert.informativeText = "Comment on the selected text (visible on hover in any browser):"
        alert.addButton(withTitle: "Add Comment")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
        field.placeholderString = "Your comment…"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            self?.editorVC.call("addComment", argument: text)
        }
    }

    private var commentPopover: NSPopover?

    private func showCommentPopover(text: String, author: String, at rect: NSRect) {
        commentPopover?.close()

        let content = NSViewController()
        let textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.preferredMaxLayoutWidth = 300

        let authorLabel = NSTextField(labelWithString: author.isEmpty ? "Comment" : author)
        authorLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        authorLabel.textColor = .secondaryLabelColor

        let editButton = NSButton(title: "Edit…", target: self, action: #selector(editCommentFromPopover(_:)))
        editButton.bezelStyle = .accessoryBarAction
        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeCommentFromPopover(_:)))
        removeButton.bezelStyle = .accessoryBarAction
        let buttons = NSStackView(views: [editButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [authorLabel, textLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: textLabel)
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        textLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        content.view = stack

        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        stack.layoutSubtreeIfNeeded()
        popover.contentSize = stack.fittingSize
        popover.show(relativeTo: rect, of: editorVC.webView, preferredEdge: .maxY)
        commentPopover = popover
    }

    @objc private func editCommentFromPopover(_ sender: Any?) {
        commentPopover?.close()
        presentEditCommentDialog()
    }

    /// Shared comment-edit dialog; expects the selection to be inside the comment.
    func presentEditCommentDialog() {
        guard let window else { return }
        editorVC.webView.evaluateJavaScript("JSON.stringify(window.Ashokan.commentAtSelection())") { [weak self] result, _ in
            var existing = ""
            if let raw = result as? String, let data = raw.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                existing = dict["text"] ?? ""
            }
            let alert = NSAlert()
            alert.messageText = "Edit Comment"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 60))
            field.stringValue = existing
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                self?.editorVC.call("editComment", argument: text)
            }
        }
    }

    @objc private func removeCommentFromPopover(_ sender: Any?) {
        commentPopover?.close()
        editorVC.call("removeComment")
    }

    @objc func toggleCommentsMargin(_ sender: Any?) {
        showingCommentsMargin.toggle()
        showCommentsButton?.state = showingCommentsMargin ? .on : .off
        editorVC.call("setCommentsMargin", argument: showingCommentsMargin)
    }

    // MARK: - Agent instructions & local AI review

    @objc func addAgentInstructions(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Add Agent Instructions"
        alert.informativeText = "Embeds an invisible instruction block (an HTML comment) that teaches AI agents like Claude Code to propose edits as tracked changes. What should the agent do?"
        alert.addButton(withTitle: "Embed Instructions")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 48))
        field.placeholderString = "Review for clarity, correctness, and tone. (default)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.embedAgentInstructions(task: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func embedAgentInstructions(task: String) {
        let comment = AgentProtocol.instructionsComment(task: task)
        if doc.format == .markdown {
            doc.markdown = comment + "\n\n" + doc.markdown
            editorVC.loadMarkdownDocument(doc.markdown)
        } else if doc.model.isFragment {
            doc.model.bodyHTML = comment + "\n" + doc.model.bodyHTML
            editorVC.loadDocument(doc.model)
        } else if let range = doc.model.prelude.range(of: "</head>", options: .caseInsensitive) {
            doc.model.prelude.insert(contentsOf: comment + "\n", at: range.lowerBound)
        } else {
            doc.model.prelude += comment + "\n"
        }
        doc.updateChangeCount(.changeDone)
        if !sourceItem.isCollapsed { sourceVC.setText(sourceText()) }
        updateStatusBar()
    }

    @objc func aiReview(_ sender: Any?) {
        guard let window else { return }
        OllamaClient.shared.listModels { [weak self] models in
            guard let self else { return }
            guard !models.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "Ollama Not Reachable"
                alert.informativeText = "No local models found at \(OllamaClient.shared.baseURL.absoluteString). Make sure Ollama is running (and has at least one model pulled)."
                alert.beginSheetModal(for: window)
                return
            }
            self.presentAIReviewSheet(models: models)
        }
    }

    private func presentAIReviewSheet(models: [String]) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "AI Review (Local Model)"
        alert.informativeText = "The document never leaves this Mac. Suggestions arrive as tracked changes you accept or reject."
        alert.addButton(withTitle: "Review")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 24), pullsDown: false)
        popup.addItems(withTitles: models)
        if let preferred = models.firstIndex(where: { $0.hasPrefix("qwen") }) {
            popup.selectItem(at: preferred)
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 44))
        field.placeholderString = "Review for clarity, correctness, and tone. (default)"
        let stack = NSStackView(views: [popup, field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 76)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let model = popup.selectedItem?.title else { return }
            var task = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if task.isEmpty { task = "Review for clarity, correctness, and tone." }
            self.runAIReview(model: model, task: task)
        }
    }

    private func runAIReview(model: String, task: String) {
        statusInfoLabel.stringValue = "AI review in progress (\(model))…"
        editorVC.webView.evaluateJavaScript("window.Ashokan.getDocText()") { [weak self] result, _ in
            guard let self, let docText = result as? String, !docText.isEmpty else {
                self?.updateStatusBar()
                return
            }
            let user = "REVIEW TASK: \(task)\n\nDOCUMENT:\n\(docText)"
            OllamaClient.shared.chat(model: model, system: AgentProtocol.ollamaSystemPrompt, user: user) { chatResult in
                switch chatResult {
                case .failure(let error):
                    self.updateStatusBar()
                    self.presentReviewError(error.localizedDescription)
                case .success(let content):
                    guard let suggestions = OllamaClient.extractSuggestions(from: content), !suggestions.isEmpty else {
                        self.updateStatusBar()
                        self.presentReviewError("The model didn't return usable suggestions. Try again or try a different model.")
                        return
                    }
                    self.applyAgentSuggestions(suggestions, author: model)
                }
            }
        }
    }

    private func applyAgentSuggestions(_ suggestions: [[String: Any]], author: String) {
        guard let window,
              let editsData = try? JSONSerialization.data(withJSONObject: suggestions),
              let editsJSON = String(data: editsData, encoding: .utf8) else { return }
        let js = "JSON.stringify(window.Ashokan.applyAgentEdits(\(editsJSON), \(Self.json(author))))"
        editorVC.webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self else { return }
            self.updateStatusBar()
            var applied = 0
            var failed = 0
            if let raw = result as? String, let data = raw.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                applied = dict["applied"] as? Int ?? 0
                failed = (dict["failed"] as? [Any])?.count ?? 0
            }
            let alert = NSAlert()
            alert.messageText = "AI Review Complete"
            var info = "\(applied) suggestion\(applied == 1 ? "" : "s") applied as tracked changes — use the review bar to accept or reject each one."
            if failed > 0 {
                info += " \(failed) couldn't be matched to the document text and were skipped."
            }
            alert.informativeText = info
            alert.beginSheetModal(for: window)
        }
    }

    private func presentReviewError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "AI Review Failed"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSuggesting(_:)) {
            menuItem.state = suggesting ? .on : .off
        }
        if menuItem.action == #selector(toggleCommentsMargin(_:)) {
            menuItem.state = showingCommentsMargin ? .on : .off
        }
        if menuItem.action == #selector(toggleReviewBar(_:)) {
            menuItem.state = isReviewBarVisible ? .on : .off
        }
        return true
    }

    // MARK: - Undo/redo routed by focus

    @objc func ashokanUndo(_ sender: Any?) {
        if sourceVC.isEditing {
            sourceVC.textView.undoManager?.undo()
        } else {
            editorVC.call("undo")
        }
    }

    @objc func ashokanRedo(_ sender: Any?) {
        if sourceVC.isEditing {
            sourceVC.textView.undoManager?.redo()
        } else {
            editorVC.call("redo")
        }
    }

    // MARK: - Source pane

    @objc func toggleSourcePane(_ sender: Any?) {
        if sourceItem.isCollapsed {
            sourceVC.setText(sourceText())
        }
        sourceItem.animator().isCollapsed.toggle()
    }

    // MARK: - Format bar (second tier, below the toolbar)

    private func buildFormatBar() -> NSView {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: ["Title", "Heading", "Subheading", "Body", "Code Block"])
        popup.selectItem(at: 3)
        popup.target = self
        popup.action = #selector(styleChanged(_:))
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        stylePopup = popup

        let tablePopup = NSPopUpButton(frame: .zero, pullsDown: true)
        let tableMenu = Self.tableMenu(target: self)
        let iconItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        iconItem.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: "Table")
        tableMenu.insertItem(iconItem, at: 0)
        tablePopup.menu = tableMenu
        tablePopup.isBordered = false
        tablePopup.toolTip = "Insert or edit a table"

        func fmtButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!,
                                  target: self, action: action)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.toolTip = tooltip
            return button
        }

        func spacer(_ width: CGFloat) -> NSView {
            let v = NSView()
            v.widthAnchor.constraint(equalToConstant: width).isActive = true
            return v
        }

        let flex = NSView()
        flex.setContentHuggingPriority(.init(1), for: .horizontal)

        let suggest = NSButton(title: "Suggest", target: self, action: #selector(toggleSuggesting(_:)))
        suggest.setButtonType(.pushOnPushOff)
        suggest.bezelStyle = .accessoryBarAction
        suggest.controlSize = .small
        suggest.image = NSImage(systemSymbolName: "pencil.line", accessibilityDescription: "Suggest Edits")
        suggest.imagePosition = .imageLeading
        suggest.toolTip = "Suggest Edits — record changes as tracked insertions and deletions"
        suggestButton = suggest

        let stack = NSStackView(views: [
            popup, spacer(6),
            fmtButton("bold", "Bold", #selector(fmtBold(_:))),
            fmtButton("italic", "Italic", #selector(fmtItalic(_:))),
            fmtButton("underline", "Underline", #selector(fmtUnderline(_:))),
            fmtButton("chevron.left.forwardslash.chevron.right", "Inline Code", #selector(fmtInlineCode(_:))),
            fmtButton("link", "Add Link", #selector(fmtLink(_:))), spacer(6),
            fmtButton("list.bullet", "Bulleted List", #selector(fmtBulletList(_:))),
            fmtButton("list.number", "Numbered List", #selector(fmtOrderedList(_:))),
            fmtButton("text.quote", "Blockquote", #selector(fmtBlockquote(_:))), spacer(6),
            fmtButton("photo", "Insert Image", #selector(insertImage(_:))),
            tablePopup,
            flex,
            suggest,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 5, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            popup.widthAnchor.constraint(equalToConstant: 110),
        ])
        return bar
    }

    // MARK: - Review bar (appears while suggesting or when the document
    // carries pending changes/comments)

    private func buildReviewBar() -> NSView {
        func iconButton(_ symbol: String, _ tooltip: String, _ action: Selector) -> NSButton {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)!,
                                  target: self, action: action)
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.toolTip = tooltip
            return button
        }
        func textButton(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            return button
        }
        func caption(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        func divider() -> NSBox {
            let box = NSBox()
            box.boxType = .separator
            box.heightAnchor.constraint(equalToConstant: 16).isActive = true
            return box
        }

        let flex = NSView()
        flex.setContentHuggingPriority(.init(1), for: .horizontal)

        acceptMenuButton = NSPopUpButton(frame: .zero, pullsDown: true)
        acceptMenuButton.isBordered = false
        acceptMenuButton.controlSize = .small
        rejectMenuButton = NSPopUpButton(frame: .zero, pullsDown: true)
        rejectMenuButton.isBordered = false
        rejectMenuButton.controlSize = .small
        rebuildBulkMenus()

        previewControl = NSSegmentedControl(labels: ["Markup", "Final", "Original"],
                                            trackingMode: .selectOne,
                                            target: self, action: #selector(previewModeChanged(_:)))
        previewControl.controlSize = .small
        previewControl.selectedSegment = 0
        previewControl.toolTip = "Preview: with markup, as if all accepted (Final), or as if all rejected (Original). View-only — the file keeps its markup."

        let stack = NSStackView(views: [
            caption("Changes"),
            iconButton("chevron.left", "Previous Change (⌥⌘[)", #selector(reviewPreviousChange(_:))),
            iconButton("chevron.right", "Next Change (⌥⌘])", #selector(reviewNextChange(_:))),
            iconButton("checkmark", "Accept Change", #selector(reviewAcceptChange(_:))),
            iconButton("xmark", "Reject Change", #selector(reviewRejectChange(_:))),
            acceptMenuButton,
            rejectMenuButton,
            divider(),
            caption("Preview"),
            previewControl,
            divider(),
            caption("Comments"),
            iconButton("chevron.left", "Previous Comment", #selector(reviewPreviousComment(_:))),
            iconButton("chevron.right", "Next Comment", #selector(reviewNextComment(_:))),
            textButton("Add…", #selector(reviewAddComment(_:))),
            {
                let button = textButton("Show All", #selector(toggleCommentsMargin(_:)))
                button.setButtonType(.pushOnPushOff)
                button.toolTip = "Show every comment as a card in the margin"
                showCommentsButton = button
                return button
            }(),
            textButton("Remove", #selector(reviewRemoveComment(_:))),
            flex,
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
        ])
        return bar
    }

    /// nil = automatic (show while suggesting or with pending review items);
    /// user toggling the Review button/menu takes explicit control.
    private var reviewBarOverride: Bool?

    // MARK: - Bulk resolve menus and preview modes

    private func rebuildBulkMenus() {
        guard acceptMenuButton != nil else { return }
        for (button, accept, title) in [(acceptMenuButton!, true, "Accept All"),
                                        (rejectMenuButton!, false, "Reject All")] {
            let menu = NSMenu()
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "")   // pulldown label
            let addItem = { (label: String, scope: [String: Any]) in
                let item = menu.addItem(withTitle: label,
                                        action: #selector(self.bulkResolve(_:)), keyEquivalent: "")
                item.target = self
                var payload = scope
                payload["accept"] = accept
                item.representedObject = payload
            }
            addItem("All Changes", [:])
            addItem("Changes in Selection", ["selection": true])
            if !changeAuthors.isEmpty {
                menu.addItem(.separator())
                for author in changeAuthors {
                    addItem("Everything by \(author)", ["author": author])
                }
            }
            button.menu = menu
        }
    }

    @objc private func bulkResolve(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: Any],
              let accept = payload["accept"] as? Bool else { return }
        var filter: [String: Any] = [:]
        if let selection = payload["selection"] as? Bool { filter["selection"] = selection }
        if let author = payload["author"] as? String { filter["author"] = author }
        let function = accept ? "acceptAllChanges" : "rejectAllChanges"
        if filter.isEmpty {
            editorVC.call(function)
        } else {
            editorVC.call(function, argument: filter)
        }
    }

    @objc private func previewModeChanged(_ sender: NSSegmentedControl) {
        let mode = ["markup", "clean", "original"][max(0, sender.selectedSegment)]
        editorVC.call("setPreviewMode", argument: mode)
    }

    var currentPreviewMode: String {
        ["markup", "clean", "original"][max(0, previewControl?.selectedSegment ?? 0)]
    }

    // MARK: - Status flash

    func flashStatus(_ message: String) {
        guard statusInfoLabel != nil else { return }
        statusInfoLabel.stringValue = message
        statusFlashUntil = Date().addingTimeInterval(4)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.1) { [weak self] in
            guard let self, Date() >= self.statusFlashUntil else { return }
            self.updateStatusBar()
        }
    }

    private func updateReviewBarVisibility() {
        let shouldShow = reviewBarOverride
            ?? (suggesting || pendingChanges > 0 || pendingComments > 0)
        if reviewAccessory.isHidden == shouldShow {
            reviewAccessory.isHidden = !shouldShow
        }
    }

    @objc func toggleReviewBar(_ sender: Any?) {
        reviewBarOverride = reviewAccessory.isHidden
        updateReviewBarVisibility()
    }

    var isReviewBarVisible: Bool { !reviewAccessory.isHidden }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) { editorVC.webView.pageZoom = min(3.0, editorVC.webView.pageZoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { editorVC.webView.pageZoom = max(0.5, editorVC.webView.pageZoom - 0.1) }
    @objc func zoomActual(_ sender: Any?) { editorVC.webView.pageZoom = 1.0 }

    // MARK: - Toolbar

    private enum ItemID {
        static let save = NSToolbarItem.Identifier("ashokan.save")
        static let exportPDF = NSToolbarItem.Identifier("ashokan.exportPDF")
        static let recents = NSToolbarItem.Identifier("ashokan.recents")
        static let review = NSToolbarItem.Identifier("ashokan.review")
        static let source = NSToolbarItem.Identifier("ashokan.source")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.save, ItemID.exportPDF, ItemID.recents,
         .flexibleSpace, ItemID.review, ItemID.source]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case ItemID.save:
            let item = button(identifier, symbol: "square.and.arrow.down", label: "Save",
                              action: #selector(NSDocument.save(_:)))
            item.target = nil   // responder chain → the document
            return item
        case ItemID.exportPDF:
            return button(identifier, symbol: "square.and.arrow.up", label: "Export as PDF",
                          action: #selector(exportPDF(_:)))
        case ItemID.recents:
            let item = button(identifier, symbol: "clock", label: "Recent Documents",
                              action: Selector(("showWelcome:")))
            item.target = nil   // responder chain → the app delegate
            return item
        case ItemID.review:
            return button(identifier, symbol: "checklist", label: "Review Bar",
                          action: #selector(toggleReviewBar(_:)))
        case ItemID.source:
            return button(identifier, symbol: "curlybraces", label: "Source", action: #selector(toggleSourcePane(_:)))
        default:
            return nil
        }
    }

    /// The table menu used by both the toolbar dropdown and the menu bar.
    /// Pass nil as target to dispatch through the responder chain.
    static func tableMenu(target: AnyObject?) -> NSMenu {
        let menu = NSMenu(title: "Table")

        let insert = NSMenuItem(title: "Insert Table", action: nil, keyEquivalent: "")
        let sizes = NSMenu(title: "Insert Table")
        for (rows, cols) in [(2, 2), (3, 3), (4, 4), (5, 5)] {
            let item = sizes.addItem(withTitle: "\(rows) × \(cols)",
                                     action: #selector(insertTable(_:)), keyEquivalent: "")
            item.tag = rows * 100 + cols
            item.target = target
        }
        sizes.addItem(.separator())
        let custom = sizes.addItem(withTitle: "Custom…",
                                   action: #selector(insertTable(_:)), keyEquivalent: "")
        custom.tag = 0
        custom.target = target
        insert.submenu = sizes
        menu.addItem(insert)
        menu.addItem(.separator())

        let commands: [(String, String)] = [
            ("Add Row Above", "addRowBefore"),
            ("Add Row Below", "addRowAfter"),
            ("Add Column Before", "addColumnBefore"),
            ("Add Column After", "addColumnAfter"),
            ("", ""),
            ("Delete Row", "deleteRow"),
            ("Delete Column", "deleteColumn"),
            ("Delete Table", "deleteTable"),
            ("", ""),
            ("Merge Cells", "mergeCells"),
            ("Split Cell", "splitCell"),
            ("Toggle Header Row", "toggleHeaderRow"),
        ]
        for (title, command) in commands {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let item = menu.addItem(withTitle: title,
                                    action: #selector(tableCommand(_:)), keyEquivalent: "")
            item.representedObject = command
            item.target = target
        }
        return menu
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier,
        symbol: String,
        label: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = label
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }
}
