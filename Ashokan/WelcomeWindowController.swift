import Cocoa
import WebKit

/// The launcher: shown on plain launch and on Dock reactivation with no
/// documents open. A grid of recently edited documents, each with a
/// live-rendered thumbnail, the filename, and the file's path beneath.
final class WelcomeWindowController: NSWindowController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let shared = WelcomeWindowController()
    private(set) static var existing: WelcomeWindowController?

    private var recents: [URL] = []
    private var collectionView: NSCollectionView!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Ashokan"
        window.isRestorable = false
        window.center()
        super.init(window: window)
        Self.existing = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        recents = (NSDocumentController.shared as? AshokanDocumentController)?.persistedRecentURLs
            ?? NSDocumentController.shared.recentDocumentURLs
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        collectionView.reloadData()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
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

        let recentLabel = NSTextField(labelWithString: "Recent Documents")
        recentLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        recentLabel.textColor = .secondaryLabelColor

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

        let root = NSStackView(views: [header, recentLabel, scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 28, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            recentLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    // MARK: - Collection view

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        recents.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: WelcomeItem.identifier, for: indexPath)
        (item as? WelcomeItem)?.configure(with: recents[indexPath.item])
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, index < recents.count else { return }
        let url = recents[index]
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
