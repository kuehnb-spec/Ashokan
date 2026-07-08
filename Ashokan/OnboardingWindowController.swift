import Cocoa

/// First-launch tour: what Ashokan is, the major features, and workspace
/// setup. Replayable from Help > Show Onboarding Tour.
final class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()
    static let onboardedKey = "AshokanDidOnboard"

    static var hasOnboarded: Bool {
        UserDefaults.standard.bool(forKey: onboardedKey)
    }

    private struct Step {
        let title: String
        let body: String
        let showsAddFolder: Bool
    }

    private let steps: [Step] = [
        Step(
            title: "Welcome to Ashokan",
            body: """
            Ashokan is a simple, fast, native editor for HTML and Markdown \
            documents — the files AI coding agents write all day.

            Edit like a word processor; the file stays plain, open HTML that \
            renders in any browser. Ashokan's core promise: it never rewrites \
            what you didn't edit. Styles, scripts, and markup it doesn't model \
            survive byte-for-byte.
            """,
            showsAddFolder: false
        ),
        Step(
            title: "Editing",
            body: """
            The format bar has styles, bold/italic, lists, links, images, and \
            tables. Markdown shortcuts work while typing: # for a heading, \
            - for a list, ``` for a code block.

            Press ⌘/ to flip open the live source pane. Images embed into the \
            file itself; tables resize by dragging column borders. File > \
            Export as PDF (⌥⌘P) makes a print-quality PDF — nothing splits \
            across pages.
            """,
            showsAddFolder: false
        ),
        Step(
            title: "Review — with humans or AIs",
            body: """
            Toggle Suggest and your edits become tracked changes — standard \
            <ins>/<del> markup that renders as redlines in any browser. Hover \
            a change for one-click ✓ accept / ✕ reject. Select text and press \
            ⌥⌘M to comment; Show All lays comments out in the margin.

            Review > AI Review sends the document to your own local Ollama \
            model — nothing leaves your Mac — and its suggestions arrive as \
            tracked changes. Add Agent Instructions embeds an invisible \
            protocol so Claude Code or Codex can redline your drafts too.
            """,
            showsAddFolder: false
        ),
        Step(
            title: "Your workspace",
            body: """
            Add the folders where you keep documents. The Welcome window shows \
            them as browsable cards with live previews, next to your recent \
            documents.

            You can always add more from the Welcome window's sidebar.
            """,
            showsAddFolder: true
        ),
    ]

    private var index = 0
    private var titleLabel: NSTextField!
    private var bodyLabel: NSTextField!
    private var backButton: NSButton!
    private var nextButton: NSButton!
    private var stepLabel: NSTextField!
    private var addFolderButton: NSButton!
    private var folderCountLabel: NSTextField!

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome"
        window.isRestorable = false
        window.center()
        super.init(window: window)
        buildUI()
        render()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        index = 0
        render()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.alignment = .center

        bodyLabel = NSTextField(wrappingLabelWithString: "")
        bodyLabel.font = .systemFont(ofSize: 14)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .natural
        bodyLabel.preferredMaxLayoutWidth = 480

        addFolderButton = NSButton(title: "Add Folder to Workspace…", target: self,
                                   action: #selector(addFolder(_:)))
        addFolderButton.bezelStyle = .rounded
        folderCountLabel = NSTextField(labelWithString: "")
        folderCountLabel.font = .systemFont(ofSize: 12)
        folderCountLabel.textColor = .tertiaryLabelColor

        stepLabel = NSTextField(labelWithString: "")
        stepLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        stepLabel.textColor = .tertiaryLabelColor

        backButton = NSButton(title: "Back", target: self, action: #selector(back(_:)))
        backButton.bezelStyle = .rounded
        nextButton = NSButton(title: "Continue", target: self, action: #selector(next(_:)))
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"

        let controls = NSStackView(views: [stepLabel, NSView(), backButton, nextButton])
        controls.orientation = .horizontal
        controls.spacing = 10
        (controls.views[1]).setContentHuggingPriority(.init(1), for: .horizontal)

        let stack = NSStackView(views: [icon, titleLabel, bodyLabel,
                                        addFolderButton, folderCountLabel, NSView(), controls])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(8, after: titleLabel)
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 48, bottom: 20, right: 48)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -96),
            bodyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 490),
        ])
    }

    private func render() {
        let step = steps[index]
        titleLabel.stringValue = step.title
        bodyLabel.stringValue = step.body
        addFolderButton.isHidden = !step.showsAddFolder
        folderCountLabel.isHidden = !step.showsAddFolder
        if step.showsAddFolder { updateFolderCount() }
        stepLabel.stringValue = "\(index + 1) of \(steps.count)"
        backButton.isHidden = index == 0
        nextButton.title = index == steps.count - 1 ? "Get Started" : "Continue"
    }

    private func updateFolderCount() {
        let count = (UserDefaults.standard.stringArray(forKey: "AshokanWorkspaceFolders") ?? []).count
        folderCountLabel.stringValue = count == 0
            ? "No folders yet — you can also do this later."
            : "\(count) folder\(count == 1 ? "" : "s") in your workspace."
    }

    @objc private func addFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Workspace"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            var folders = UserDefaults.standard.stringArray(forKey: "AshokanWorkspaceFolders") ?? []
            for url in panel.urls where !folders.contains(url.path) {
                folders.append(url.path)
            }
            UserDefaults.standard.set(folders, forKey: "AshokanWorkspaceFolders")
            self?.updateFolderCount()
        }
    }

    @objc private func back(_ sender: Any?) {
        guard index > 0 else { return }
        index -= 1
        render()
    }

    @objc private func next(_ sender: Any?) {
        if index < steps.count - 1 {
            index += 1
            render()
        } else {
            UserDefaults.standard.set(true, forKey: Self.onboardedKey)
            close()
            WelcomeWindowController.shared.show()
        }
    }
}
