import Cocoa
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSToolbarDelegate {
    let editorVC = EditorViewController()
    let sourceVC = SourceViewController()
    private let splitVC = NSSplitViewController()
    private var sourceItem: NSSplitViewItem!
    private var stylePopup: NSPopUpButton!
    private var statusPathLabel: NSTextField!
    private var statusInfoLabel: NSTextField!
    private var lastWordCount = 0

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
            if self.doc.format == .markdown {
                self.doc.markdown = markdown ?? self.doc.markdown
            } else {
                self.doc.model.bodyHTML = bodyHTML
            }
            self.doc.updateChangeCount(.changeDone)
            self.lastWordCount = words
            self.updateStatusBar()
            if !self.sourceItem.isCollapsed && !self.sourceVC.isEditing {
                self.sourceVC.setText(self.sourceText())
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
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = doc.displayName
            .replacingOccurrences(of: ".html", with: "") + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.editorVC.exportPDF(to: url)
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
        ])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 5, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            popup.widthAnchor.constraint(equalToConstant: 110),
        ])
        return bar
    }

    // MARK: - Zoom

    @objc func zoomIn(_ sender: Any?) { editorVC.webView.pageZoom = min(3.0, editorVC.webView.pageZoom + 0.1) }
    @objc func zoomOut(_ sender: Any?) { editorVC.webView.pageZoom = max(0.5, editorVC.webView.pageZoom - 0.1) }
    @objc func zoomActual(_ sender: Any?) { editorVC.webView.pageZoom = 1.0 }

    // MARK: - Toolbar

    private enum ItemID {
        static let save = NSToolbarItem.Identifier("ashokan.save")
        static let exportPDF = NSToolbarItem.Identifier("ashokan.exportPDF")
        static let recents = NSToolbarItem.Identifier("ashokan.recents")
        static let source = NSToolbarItem.Identifier("ashokan.source")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.save, ItemID.exportPDF, ItemID.recents,
         .flexibleSpace, ItemID.source]
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
