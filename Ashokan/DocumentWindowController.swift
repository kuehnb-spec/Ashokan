import Cocoa
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSToolbarDelegate {
    let editorVC = EditorViewController()
    let sourceVC = SourceViewController()
    private let splitVC = NSSplitViewController()
    private var sourceItem: NSSplitViewItem!
    private var stylePopup: NSPopUpButton!

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
        window.contentViewController = splitVC
        // Setting contentViewController resizes the window to the content's
        // fitting size — which is ~zero for an unconstrained split view.
        window.setContentSize(NSSize(width: 1080, height: 780))
        window.center()

        let toolbar = NSToolbar(identifier: "AshokanToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

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
        editorVC.onBodyChanged = { [weak self] bodyHTML in
            guard let self else { return }
            self.doc.model.bodyHTML = bodyHTML
            self.doc.updateChangeCount(.changeDone)
            if !self.sourceItem.isCollapsed && !self.sourceVC.isEditing {
                self.sourceVC.setText(self.doc.model.assembled())
            }
        }
        sourceVC.onTextChanged = { [weak self] text in
            guard let self else { return }
            self.doc.model = HTMLDocumentModel.parse(text)
            self.doc.updateChangeCount(.changeDone)
            self.editorVC.loadDocument(self.doc.model)
        }
    }

    private func loadEditor() {
        // Untitled windows stay out of state restoration so a template-bearing
        // "Untitled" doesn't get preserved as a draft and resurrected forever.
        window?.isRestorable = doc.fileURL != nil
        editorVC.loadShell(baseURL: doc.fileURL?.deletingLastPathComponent())
        editorVC.loadDocument(doc.model)
    }

    /// Called when the document re-reads its file (e.g. Revert to Saved).
    func documentDidReload() {
        editorVC.loadDocument(doc.model)
        if !sourceItem.isCollapsed {
            sourceVC.setText(doc.model.assembled())
        }
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
            sourceVC.setText(doc.model.assembled())
        }
        sourceItem.animator().isCollapsed.toggle()
    }

    // MARK: - Toolbar

    private enum ItemID {
        static let style = NSToolbarItem.Identifier("ashokan.style")
        static let bold = NSToolbarItem.Identifier("ashokan.bold")
        static let italic = NSToolbarItem.Identifier("ashokan.italic")
        static let code = NSToolbarItem.Identifier("ashokan.code")
        static let link = NSToolbarItem.Identifier("ashokan.link")
        static let bulletList = NSToolbarItem.Identifier("ashokan.bulletList")
        static let orderedList = NSToolbarItem.Identifier("ashokan.orderedList")
        static let blockquote = NSToolbarItem.Identifier("ashokan.blockquote")
        static let image = NSToolbarItem.Identifier("ashokan.image")
        static let table = NSToolbarItem.Identifier("ashokan.table")
        static let source = NSToolbarItem.Identifier("ashokan.source")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.style, .space,
         ItemID.bold, ItemID.italic, ItemID.code, ItemID.link, .space,
         ItemID.bulletList, ItemID.orderedList, ItemID.blockquote, .space,
         ItemID.image, ItemID.table,
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
        case ItemID.style:
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 130, height: 24), pullsDown: false)
            popup.addItems(withTitles: ["Title", "Heading", "Subheading", "Body", "Code Block"])
            popup.selectItem(at: 3)
            popup.target = self
            popup.action = #selector(styleChanged(_:))
            stylePopup = popup
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = popup
            item.label = "Style"
            return item
        case ItemID.bold:
            return button(identifier, symbol: "bold", label: "Bold", action: #selector(fmtBold(_:)))
        case ItemID.italic:
            return button(identifier, symbol: "italic", label: "Italic", action: #selector(fmtItalic(_:)))
        case ItemID.code:
            return button(identifier, symbol: "chevron.left.forwardslash.chevron.right", label: "Code", action: #selector(fmtInlineCode(_:)))
        case ItemID.link:
            return button(identifier, symbol: "link", label: "Link", action: #selector(fmtLink(_:)))
        case ItemID.bulletList:
            return button(identifier, symbol: "list.bullet", label: "Bulleted List", action: #selector(fmtBulletList(_:)))
        case ItemID.orderedList:
            return button(identifier, symbol: "list.number", label: "Numbered List", action: #selector(fmtOrderedList(_:)))
        case ItemID.blockquote:
            return button(identifier, symbol: "text.quote", label: "Blockquote", action: #selector(fmtBlockquote(_:)))
        case ItemID.image:
            return button(identifier, symbol: "photo", label: "Insert Image", action: #selector(insertImage(_:)))
        case ItemID.table:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: "Table")
            item.label = "Table"
            item.toolTip = "Insert or edit a table"
            item.showsIndicator = true
            item.menu = Self.tableMenu(target: self)
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
