import Cocoa

/// The source pane: a plain, fast, native text view over the full file.
final class SourceViewController: NSViewController, NSTextViewDelegate {
    private var scrollView: NSScrollView!
    private(set) var textView: NSTextView!
    private var programmaticUpdate = false
    private var pendingChange: DispatchWorkItem?

    var onTextChanged: ((String) -> Void)?

    override func loadView() {
        scrollView = NSTextView.scrollableTextView()
        textView = (scrollView.documentView as! NSTextView)

        textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.delegate = self

        view = scrollView
    }

    // The pane starts collapsed, so the view may not exist yet when the
    // document first pushes text — load on demand (a nil textView here
    // crashed the app; caught by the QA sweep).
    var text: String {
        loadViewIfNeeded()
        return textView.string
    }

    func setText(_ text: String) {
        loadViewIfNeeded()
        guard textView.string != text else { return }
        programmaticUpdate = true
        textView.string = text
        programmaticUpdate = false
    }

    var isEditing: Bool {
        isViewLoaded && view.window?.firstResponder === textView
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !programmaticUpdate else { return }
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onTextChanged?(self.textView.string)
        }
        pendingChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
