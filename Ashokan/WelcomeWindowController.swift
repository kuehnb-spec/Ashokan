import Cocoa
import WebKit

/// The launcher: shown on plain launch and on Dock reactivation with no
/// documents open. A grid of recently edited documents, each with a
/// live-rendered thumbnail, the filename, and the file's path beneath.
final class WelcomeWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate {
    static let shared = WelcomeWindowController()
    private(set) static var existing: WelcomeWindowController?

    private static let foldersKey = "AshokanWorkspaceFolders"

    private var gridURLs: [URL] = []
    private var collectionView: NSCollectionView!
    private var sidebarTable: NSTableView!
    private var workspaceFolders: [URL] = []
    /// nil = Recents; otherwise the selected workspace folder.
    private var selectedFolder: URL?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Ashokan"
        window.isRestorable = false
        window.center()
        super.init(window: window)
        Self.existing = self
        workspaceFolders = (UserDefaults.standard.stringArray(forKey: Self.foldersKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        sidebarTable.reloadData()
        let row = selectedFolder.flatMap { folder in
            workspaceFolders.firstIndex(of: folder).map { $0 + 1 }
        } ?? 0
        sidebarTable.selectRowIndexes([row], byExtendingSelection: false)
        reloadGrid()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func reloadGrid() {
        if let folder = selectedFolder {
            gridURLs = Self.documents(in: folder)
        } else {
            gridURLs = (NSDocumentController.shared as? AshokanDocumentController)?.persistedRecentURLs
                ?? NSDocumentController.shared.recentDocumentURLs
                    .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        collectionView.reloadData()
    }

    private static func documents(in folder: URL) -> [URL] {
        let extensions = Set(["html", "htm", "md", "markdown"])
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
            .prefix(60)
            .map { $0 }
    }

    // MARK: - Workspace folder management

    @objc private func addWorkspaceFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders where you keep HTML and Markdown documents"
        panel.prompt = "Add to Workspace"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls where !self.workspaceFolders.contains(url) {
                self.workspaceFolders.append(url)
            }
            self.persistFolders()
            self.sidebarTable.reloadData()
        }
    }

    @objc private func removeWorkspaceFolder(_ sender: Any?) {
        let row = sidebarTable.clickedRow
        guard row > 0, row - 1 < workspaceFolders.count else { return }
        let removed = workspaceFolders.remove(at: row - 1)
        if selectedFolder == removed { selectedFolder = nil }
        persistFolders()
        sidebarTable.reloadData()
        sidebarTable.selectRowIndexes([0], byExtendingSelection: false)
        reloadGrid()
    }

    private func persistFolders() {
        UserDefaults.standard.set(workspaceFolders.map(\.path), forKey: Self.foldersKey)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Ashokan")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        let subtitle = NSTextField(labelWithString: "A simple, fast, native editor for HTML documents")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let newButton = NSButton(title: "New Document", target: nil,
                                 action: #selector(NSDocumentController.newDocument(_:)))
        newButton.bezelStyle = .rounded
        newButton.keyEquivalent = "\r"
        let openButton = NSButton(title: "Open…", target: nil,
                                  action: #selector(NSDocumentController.openDocument(_:)))
        openButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [newButton, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let header = NSStackView(views: [title, subtitle, buttons])
        header.orientation = .vertical
        header.alignment = .centerX
        header.spacing = 6
        header.setCustomSpacing(14, after: subtitle)

        // Sidebar: Recents + workspace folders.
        sidebarTable = NSTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sidebarTable.addTableColumn(column)
        sidebarTable.headerView = nil
        sidebarTable.rowHeight = 26
        sidebarTable.style = .sourceList
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        let sidebarMenu = NSMenu()
        sidebarMenu.addItem(withTitle: "Remove Folder from Workspace",
                            action: #selector(removeWorkspaceFolder(_:)), keyEquivalent: "")
            .target = self
        sidebarTable.menu = sidebarMenu

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false

        let addFolder = NSButton(title: "Add Folder…", target: self,
                                 action: #selector(addWorkspaceFolder(_:)))
        addFolder.bezelStyle = .accessoryBarAction
        addFolder.controlSize = .small

        let sidebar = NSStackView(views: [sidebarScroll, addFolder])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 6
        sidebar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 12, right: 0)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 224, height: 208)
        layout.sectionInset = NSEdgeInsets(top: 8, left: 24, bottom: 24, right: 24)
        layout.minimumInteritemSpacing = 18
        layout.minimumLineSpacing = 22

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.backgroundColors = [.clear]
        collectionView.register(WelcomeItem.self,
                                forItemWithIdentifier: WelcomeItem.identifier)

        let scroll = NSScrollView()
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let body = NSStackView(views: [sidebar, scroll])
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 8

        let root = NSStackView(views: [header, body])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            body.widthAnchor.constraint(equalTo: content.widthAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            sidebar.heightAnchor.constraint(equalTo: body.heightAnchor),
        ])
    }

    // MARK: - Sidebar table

    func numberOfRows(in tableView: NSTableView) -> Int {
        1 + workspaceFolders.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        if row == 0 {
            icon.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
            label.stringValue = "Recents"
        } else {
            let folder = workspaceFolders[row - 1]
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            label.stringValue = folder.lastPathComponent
            cell.toolTip = folder.path
        }
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = sidebarTable.selectedRow
        selectedFolder = row > 0 && row - 1 < workspaceFolders.count ? workspaceFolders[row - 1] : nil
        reloadGrid()
    }

    // MARK: - Collection view

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        gridURLs.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: WelcomeItem.identifier, for: indexPath)
        (item as? WelcomeItem)?.configure(with: gridURLs[indexPath.item])
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, index < gridURLs.count else { return }
        let url = gridURLs[index]
        collectionView.deselectItems(at: indexPaths)
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}

// MARK: - Grid item

final class WelcomeItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("WelcomeItem")

    private let thumb = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private var currentURL: URL?

    override func loadView() {
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        thumb.layer?.borderColor = NSColor.separatorColor.cgColor
        thumb.layer?.borderWidth = 1
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false

        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.alignment = .center
        path.font = .systemFont(ofSize: 10.5)
        path.textColor = .tertiaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        path.alignment = .center

        let stack = NSStackView(views: [thumb, name, path])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
        view = stack

        NSLayoutConstraint.activate([
            thumb.widthAnchor.constraint(equalToConstant: 216),
            thumb.heightAnchor.constraint(equalToConstant: 150),
            name.widthAnchor.constraint(lessThanOrEqualToConstant: 216),
            path.widthAnchor.constraint(lessThanOrEqualToConstant: 216),
        ])
    }

    func configure(with url: URL) {
        currentURL = url
        name.stringValue = url.lastPathComponent
        path.stringValue = url.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
        path.toolTip = url.path
        thumb.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        ThumbnailRenderer.shared.thumbnail(for: url) { [weak self] image in
            guard let self, self.currentURL == url, let image else { return }
            self.thumb.image = image
        }
    }
}

// MARK: - Thumbnail rendering

/// Renders document thumbnails with an offscreen WKWebView, one at a time,
/// cached by file path + modification date.
final class ThumbnailRenderer: NSObject, WKNavigationDelegate {
    static let shared = ThumbnailRenderer()

    private let cacheDir: URL
    private var queue: [(URL, (NSImage?) -> Void)] = []
    private var busy = false
    private var hostWindow: NSWindow?
    private var webView: WKWebView?
    private var completion: ((NSImage?) -> Void)?
    private var cacheFile: URL?
    private var timeoutWork: DispatchWorkItem?

    private override init() {
        cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.brantkuehn.Ashokan/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        super.init()
    }

    func thumbnail(for url: URL, completion: @escaping (NSImage?) -> Void) {
        let key = cacheKey(for: url)
        let cached = cacheDir.appendingPathComponent(key + ".png")
        if let image = NSImage(contentsOf: cached) {
            completion(image)
            return
        }
        queue.append((url, completion))
        renderNext()
    }

    private func cacheKey(for url: URL) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            .flatMap { $0 }?.timeIntervalSince1970 ?? 0
        let raw = "\(url.path)|\(mtime)"
        return String(raw.hashValue, radix: 36).replacingOccurrences(of: "-", with: "n")
    }

    private func renderNext() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let (url, completion) = queue.removeFirst()
        self.completion = completion
        self.cacheFile = cacheDir.appendingPathComponent(cacheKey(for: url) + ".png")

        // An invisible (alpha 0) offscreen window keeps WebKit rendering real
        // frames without anything appearing on screen.
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 830),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.isRestorable = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 830))
        web.navigationDelegate = self
        window.contentView = web
        window.orderBack(nil)
        hostWindow = window
        webView = web
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        let timeout = DispatchWorkItem { [weak self] in self?.finish(nil) }
        timeoutWork = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let web = self.webView else { return }
            let config = WKSnapshotConfiguration()
            config.snapshotWidth = 432   // 2x the 216pt card width
            web.takeSnapshot(with: config) { image, _ in
                self.finish(image)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func finish(_ image: NSImage?) {
        timeoutWork?.cancel()
        timeoutWork = nil
        if let image, let cacheFile,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: cacheFile)
        }
        completion?(image)
        completion = nil
        webView?.navigationDelegate = nil
        webView = nil
        hostWindow?.orderOut(nil)
        hostWindow = nil
        busy = false
        renderNext()
    }
}
