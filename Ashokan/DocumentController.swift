import Cocoa

/// NSDocumentController with its own recents persistence. The system recents
/// service (sharedfilelistd) declines to persist for ad-hoc-signed dev
/// builds, so recents are mirrored into UserDefaults and merged on read.
final class AshokanDocumentController: NSDocumentController {
    private static let recentsKey = "AshokanRecentDocuments"

    override func noteNewRecentDocumentURL(_ url: URL) {
        super.noteNewRecentDocumentURL(url)
        var paths = UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(20)), forKey: Self.recentsKey)
    }

    override func clearRecentDocuments(_ sender: Any?) {
        super.clearRecentDocuments(sender)
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
    }

    /// System recents merged with our persisted list, newest first,
    /// existing files only.
    var persistedRecentURLs: [URL] {
        let stored = (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        var merged: [URL] = []
        for url in recentDocumentURLs + stored where seen.insert(url.path).inserted {
            merged.append(url)
        }
        return merged.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Feed persisted recents back into the live controller at launch so the
    /// File > Open Recent menu survives relaunches too.
    func restorePersistedRecents() {
        let stored = (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        for url in stored.reversed() {
            noteNewRecentDocumentURL(url)
        }
    }
}
