import Cocoa

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
        self.document = document

        let editorItem = NSSplitViewItem(viewController: editorVC)
        editorItem.minimumThickness = 320

        sourceItem = NSSplitViewItem(viewController: sourceVC)
        sourceItem.minimumThickness = 280
        sourceItem.canCollapse = true
        sourceItem.isCollapsed = true

        splitVC.addSplitViewItem(editorItem)
        splitVC.addSplitViewItem(sourceItem)
        window.contentViewController = splitVC

        let toolbar = NSToolbar(identifier: "AshokanToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        wireUp()
        loadEditor()
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
        static let source = NSToolbarItem.Identifier("ashokan.source")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ItemID.style, .space,
         ItemID.bold, ItemID.italic, ItemID.code, ItemID.link, .space,
         ItemID.bulletList, ItemID.orderedList, ItemID.blockquote,
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
        case ItemID.source:
            return button(identifier, symbol: "curlybraces", label: "Source", action: #selector(toggleSourcePane(_:)))
        default:
            return nil
        }
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
