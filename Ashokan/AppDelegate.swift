import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Instantiating our controller first makes it the shared instance.
        _ = AshokanDocumentController()
        NSApp.mainMenu = buildMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        (NSDocumentController.shared as? AshokanDocumentController)?.restorePersistedRecents()
        // On a plain launch (no file to open), show the Welcome launcher.
        // The small delay lets file-open events delivered around launch win.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if NSDocumentController.shared.documents.isEmpty {
                WelcomeWindowController.shared.show()
            }
        }
    }

    // The Welcome launcher replaces the automatic untitled window.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            WelcomeWindowController.shared.show()
            return false
        }
        return true
    }

    @objc func showWelcome(_ sender: Any?) {
        WelcomeWindowController.shared.show()
    }

    // MARK: - Menu construction

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // Application
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Ashokan",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Ashokan",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Ashokan",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenu: appMenu, title: "Ashokan")

        // File
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New",
                         action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        // AppKit recognizes this shape (submenu ending in clearRecentDocuments:)
        // and populates it with the document controller's recents.
        let openRecent = NSMenu(title: "Open Recent")
        openRecent.addItem(withTitle: "Clear Menu",
                           action: #selector(NSDocumentController.clearRecentDocuments(_:)),
                           keyEquivalent: "")
        fileMenu.addItem(submenu: openRecent, title: "Open Recent")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save…",
                         action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = fileMenu.addItem(withTitle: "Save As…",
                                      action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(withTitle: "Revert to Saved",
                         action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        let exportPDF = fileMenu.addItem(withTitle: "Export as PDF…",
                                         action: Selector(("exportPDF:")), keyEquivalent: "p")
        exportPDF.keyEquivalentModifierMask = [.command, .option]
        mainMenu.addItem(submenu: fileMenu, title: "File")

        // Edit
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("ashokanUndo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("ashokanRedo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(submenu: editMenu, title: "Edit")

        // Insert
        let insertMenu = NSMenu(title: "Insert")
        let insertImage = insertMenu.addItem(withTitle: "Image…",
                                             action: Selector(("insertImage:")), keyEquivalent: "i")
        insertImage.keyEquivalentModifierMask = [.command, .shift]
        insertMenu.addItem(withTitle: "Horizontal Rule",
                           action: Selector(("fmtHorizontalRule:")), keyEquivalent: "")
        mainMenu.addItem(submenu: insertMenu, title: "Insert")

        // Table (also available from the toolbar's table dropdown)
        mainMenu.addItem(submenu: DocumentWindowController.tableMenu(target: nil), title: "Table")

        // Format
        let formatMenu = NSMenu(title: "Format")
        formatMenu.addItem(withTitle: "Bold", action: Selector(("fmtBold:")), keyEquivalent: "b")
        formatMenu.addItem(withTitle: "Italic", action: Selector(("fmtItalic:")), keyEquivalent: "i")
        formatMenu.addItem(withTitle: "Underline", action: Selector(("fmtUnderline:")), keyEquivalent: "u")
        formatMenu.addItem(withTitle: "Strikethrough", action: Selector(("fmtStrike:")), keyEquivalent: "")
        formatMenu.addItem(withTitle: "Inline Code", action: Selector(("fmtInlineCode:")), keyEquivalent: "e")
        formatMenu.addItem(.separator())
        addStyleItem(formatMenu, "Title", "fmtH1:", "1")
        addStyleItem(formatMenu, "Heading", "fmtH2:", "2")
        addStyleItem(formatMenu, "Subheading", "fmtH3:", "3")
        addStyleItem(formatMenu, "Heading 4", "fmtH4:", "4")
        addStyleItem(formatMenu, "Body", "fmtBody:", "0")
        formatMenu.addItem(.separator())
        formatMenu.addItem(withTitle: "Bulleted List", action: Selector(("fmtBulletList:")), keyEquivalent: "")
        formatMenu.addItem(withTitle: "Numbered List", action: Selector(("fmtOrderedList:")), keyEquivalent: "")
        let quote = formatMenu.addItem(withTitle: "Blockquote", action: Selector(("fmtBlockquote:")), keyEquivalent: "'")
        quote.keyEquivalentModifierMask = [.command]
        addStyleItem(formatMenu, "Code Block", "fmtCodeBlock:", "c")
        formatMenu.addItem(.separator())
        let imageFormat = NSMenuItem(title: "Image", action: nil, keyEquivalent: "")
        let imageSub = NSMenu(title: "Image")
        for (title, mode) in [("Inline with Text", "inline"), ("Float Left", "left"),
                              ("Float Right", "right"), ("Centered", "center")] {
            let item = imageSub.addItem(withTitle: title,
                                        action: Selector(("alignImage:")), keyEquivalent: "")
            item.representedObject = mode
        }
        imageFormat.submenu = imageSub
        formatMenu.addItem(imageFormat)
        formatMenu.addItem(.separator())
        formatMenu.addItem(withTitle: "Add Link…", action: Selector(("fmtLink:")), keyEquivalent: "k")
        mainMenu.addItem(submenu: formatMenu, title: "Format")

        // Review
        let reviewMenu = NSMenu(title: "Review")
        let suggest = reviewMenu.addItem(withTitle: "Suggest Edits",
                                         action: Selector(("toggleSuggesting:")), keyEquivalent: "e")
        suggest.keyEquivalentModifierMask = [.command, .shift]
        reviewMenu.addItem(.separator())
        let prevChange = reviewMenu.addItem(withTitle: "Previous Change",
                                            action: Selector(("reviewPreviousChange:")), keyEquivalent: "[")
        prevChange.keyEquivalentModifierMask = [.command, .option]
        let nextChange = reviewMenu.addItem(withTitle: "Next Change",
                                            action: Selector(("reviewNextChange:")), keyEquivalent: "]")
        nextChange.keyEquivalentModifierMask = [.command, .option]
        reviewMenu.addItem(withTitle: "Accept Change",
                           action: Selector(("reviewAcceptChange:")), keyEquivalent: "")
        reviewMenu.addItem(withTitle: "Reject Change",
                           action: Selector(("reviewRejectChange:")), keyEquivalent: "")
        reviewMenu.addItem(withTitle: "Accept All Changes",
                           action: Selector(("reviewAcceptAll:")), keyEquivalent: "")
        reviewMenu.addItem(withTitle: "Reject All Changes",
                           action: Selector(("reviewRejectAll:")), keyEquivalent: "")
        reviewMenu.addItem(.separator())
        let addComment = reviewMenu.addItem(withTitle: "Add Comment…",
                                            action: Selector(("reviewAddComment:")), keyEquivalent: "m")
        addComment.keyEquivalentModifierMask = [.command, .option]
        reviewMenu.addItem(withTitle: "Show Comment",
                           action: Selector(("reviewShowComment:")), keyEquivalent: "")
        reviewMenu.addItem(withTitle: "Remove Comment",
                           action: Selector(("reviewRemoveComment:")), keyEquivalent: "")
        reviewMenu.addItem(withTitle: "Previous Comment",
                           action: Selector(("reviewPreviousComment:")), keyEquivalent: "")
        reviewMenu.addItem(withTitle: "Next Comment",
                           action: Selector(("reviewNextComment:")), keyEquivalent: "")
        mainMenu.addItem(submenu: reviewMenu, title: "Review")

        // View
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Source", action: Selector(("toggleSourcePane:")), keyEquivalent: "/")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Zoom In", action: Selector(("zoomIn:")), keyEquivalent: "=")
        viewMenu.addItem(withTitle: "Zoom Out", action: Selector(("zoomOut:")), keyEquivalent: "-")
        viewMenu.addItem(withTitle: "Actual Size", action: Selector(("zoomActual:")), keyEquivalent: "0")
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        mainMenu.addItem(submenu: viewMenu, title: "View")

        // Window
        let windowMenu = NSMenu(title: "Window")
        let welcome = windowMenu.addItem(withTitle: "Welcome to Ashokan",
                                         action: #selector(showWelcome(_:)), keyEquivalent: "1")
        welcome.keyEquivalentModifierMask = [.command, .shift]
        welcome.target = self
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Show Previous Tab",
                           action: #selector(NSWindow.selectPreviousTab(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Show Next Tab",
                           action: #selector(NSWindow.selectNextTab(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Move Tab to New Window",
                           action: #selector(NSWindow.moveTabToNewWindow(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Merge All Windows",
                           action: #selector(NSWindow.mergeAllWindows(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        mainMenu.addItem(submenu: windowMenu, title: "Window")
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private func addStyleItem(_ menu: NSMenu, _ title: String, _ selector: String, _ key: String) {
        let item = menu.addItem(withTitle: title, action: Selector((selector)), keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command, .option]
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
