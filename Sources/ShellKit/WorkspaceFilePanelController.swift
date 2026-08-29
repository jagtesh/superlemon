// WorkspaceFilePanelController — a sheet-style file dialog for a workspace
// whose filesystem is reachable only through a `DirectoryLister`. NSOpenPanel
// and NSSavePanel talk directly to this machine's filesystem, which is wrong
// for a remote (ssh) session: this panel reuses FileTreeSidebarView (the same
// lazy, listing-backed tree the workspace sidebar shows) so browsing behaves
// identically and works over whatever transport the caller's lister reaches.

import AppKit

/// What a `WorkspaceFilePanelController` collects.
public enum WorkspaceFilePanelMode: Sendable, Equatable {
    /// Pick an existing file.
    case openFile
    /// Pick an existing directory.
    case openDirectory
    /// Pick a directory and type a name; the target need not exist yet.
    case saveFile(defaultName: String)
}

/// A sheet presenting a `FileTreeSidebarView` over `lister`'s filesystem plus
/// Cancel/primary controls (and, for `.saveFile`, a name field). Construct
/// one, call `beginSheet(on:completion:)`, and read the chosen absolute path
/// (or nil on cancel) from the completion.
@MainActor
public final class WorkspaceFilePanelController: NSWindowController, NSTextFieldDelegate {
    public static let contentSize = NSSize(width: 560, height: 420)
    private static let minimumContentSize = NSSize(width: 420, height: 320)

    private let mode: WorkspaceFilePanelMode
    private let root: URL

    /// Test seam: the tree this panel browses.
    let sidebar: FileTreeSidebarView
    /// Test seam: non-nil only for `.saveFile`.
    let nameField: NSTextField?
    private let pathLabel = NSTextField(labelWithString: "")
    private let saveLabel = NSTextField(labelWithString: "Save As:")
    private let cancelButton: NSButton
    private let primaryButton: NSButton

    /// Test seam: installed by `beginSheet`, or directly by a test that never
    /// presents the sheet. `confirm()`/`cancel()` call this exactly once.
    var completion: (@MainActor (String?) -> Void)?
    private var finished = false

    public init(
        lister: DirectoryLister, root: URL, mode: WorkspaceFilePanelMode,
        title: String? = nil
    ) {
        self.mode = mode
        self.root = root.standardizedFileURL
        sidebar = FileTreeSidebarView(
            frame: NSRect(origin: .zero, size: Self.contentSize), lister: lister)
        if case .saveFile(let defaultName) = mode {
            nameField = NSTextField(string: defaultName)
        } else {
            nameField = nil
        }
        cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        primaryButton = NSButton(title: Self.primaryTitle(for: mode), target: nil, action: nil)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.title = title ?? Self.defaultTitle(for: mode)
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumContentSize

        super.init(window: window)

        // Local filesystem affordances (New File/Folder, Rename, Move to
        // Trash, Reveal in Finder) don't belong in a picker, and a poll on
        // every expansion keeps a remote listing honest without FSEvents.
        sidebar.allowsFileOperations = false
        sidebar.refreshesOnExpand = true

        buildUI(in: window)
        wireActions()
        NotificationCenter.default.addObserver(
            self, selector: #selector(outlineSelectionNotification),
            name: NSTableView.selectionDidChangeNotification, object: sidebar.outlineView)

        sidebar.setRoot(self.root)
        updatePathLabel()
        updatePrimaryButtonEnabled()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    private func buildUI(in window: NSWindow) {
        let content = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        window.contentView = content

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pathLabel)

        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cancelButton)

        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(primaryButton)
        window.defaultButtonCell = primaryButton.cell as? NSButtonCell

        var bottomAnchorAboveButtons = sidebar.bottomAnchor.constraint(
            equalTo: cancelButton.topAnchor, constant: -12)

        if let nameField {
            saveLabel.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(saveLabel)
            nameField.delegate = self
            nameField.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(nameField)

            bottomAnchorAboveButtons = sidebar.bottomAnchor.constraint(
                equalTo: saveLabel.topAnchor, constant: -10)
            NSLayoutConstraint.activate([
                saveLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                saveLabel.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
                nameField.leadingAnchor.constraint(
                    equalTo: saveLabel.trailingAnchor, constant: 8),
                nameField.trailingAnchor.constraint(
                    equalTo: content.trailingAnchor, constant: -16),
                nameField.bottomAnchor.constraint(
                    equalTo: cancelButton.topAnchor, constant: -12),
            ])
        }

        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            pathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -16),

            sidebar.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 8),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomAnchorAboveButtons,

            cancelButton.trailingAnchor.constraint(
                equalTo: primaryButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(
                equalTo: content.bottomAnchor, constant: -16),

            primaryButton.trailingAnchor.constraint(
                equalTo: content.trailingAnchor, constant: -16),
            primaryButton.bottomAnchor.constraint(
                equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    private func wireActions() {
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        primaryButton.target = self
        primaryButton.action = #selector(confirmTapped)

        // Double-clicking a file confirms an .openFile pick outright; every
        // other mode leaves double-click to the tree's own expand/collapse.
        sidebar.onOpenFilePermanently = { [weak self] path in
            guard let self, self.mode == .openFile else { return }
            self.finish(with: path)
        }
    }

    private static func defaultTitle(for mode: WorkspaceFilePanelMode) -> String {
        switch mode {
        case .openFile: return "Open File"
        case .openDirectory: return "Open Folder"
        case .saveFile: return "Save File"
        }
    }

    private static func primaryTitle(for mode: WorkspaceFilePanelMode) -> String {
        switch mode {
        case .openFile, .openDirectory: return "Open"
        case .saveFile: return "Save"
        }
    }

    // MARK: - Selection / name-field state

    private func selectedNode() -> FileTreeNode? {
        let row = sidebar.outlineView.selectedRow
        guard row >= 0 else { return nil }
        // The synthetic ".." row isn't a FileTreeNode; treated as "nothing
        // selected" below, which is the right fallback (root) for every mode.
        return sidebar.outlineView.item(atRow: row) as? FileTreeNode
    }

    /// The directory a save (or a fallback open-directory) action targets:
    /// the selected directory row, the parent of a selected file row, or
    /// `root` when nothing is selected.
    private func selectedDirectory() -> URL {
        guard let node = selectedNode() else { return root }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    /// Test seam: what pressing the primary button right now would hand the
    /// completion. `nil` exactly when the primary button should be (and is)
    /// disabled.
    var selectedPath: String? {
        switch mode {
        case .openDirectory:
            guard let node = selectedNode() else { return root.path }
            return node.isDirectory ? node.url.path : nil
        case .openFile:
            guard let node = selectedNode(), !node.isDirectory else { return nil }
            return node.url.path
        case .saveFile:
            let name = nameField?.stringValue ?? ""
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return selectedDirectory().appendingPathComponent(name).path
        }
    }

    @objc private func outlineSelectionNotification() {
        selectionDidChange()
    }

    /// Test seam: the effect of an outline-view selection change, callable
    /// directly so tests don't depend on notification delivery timing.
    func selectionDidChange() {
        if case .saveFile = mode, let node = selectedNode(), !node.isDirectory {
            nameField?.stringValue = node.name
        }
        updatePathLabel()
        updatePrimaryButtonEnabled()
    }

    public func controlTextDidChange(_ obligation: Notification) {
        updatePathLabel()
        updatePrimaryButtonEnabled()
    }

    private func updatePathLabel() {
        switch mode {
        case .openFile, .openDirectory:
            pathLabel.stringValue = selectedNode()?.url.path ?? root.path
        case .saveFile:
            pathLabel.stringValue = selectedDirectory().path
        }
    }

    private func updatePrimaryButtonEnabled() {
        primaryButton.isEnabled = selectedPath != nil
    }

    // MARK: - Confirm / cancel

    @objc private func confirmTapped() { _ = confirm() }
    @objc private func cancelTapped() { cancel() }

    /// Test seam: same effect as pressing the primary button. Returns the
    /// resolved path (nil, and a no-op, when the primary button would be
    /// disabled or the panel already finished).
    @discardableResult
    func confirm() -> String? {
        guard let path = selectedPath else { return nil }
        finish(with: path)
        return path
    }

    /// Test seam: same effect as pressing Cancel.
    func cancel() {
        finish(with: nil)
    }

    private func finish(with path: String?) {
        guard !finished else { return }
        finished = true
        if let sheetWindow = window, let parent = sheetWindow.sheetParent {
            parent.endSheet(sheetWindow)
        }
        let completion = self.completion
        self.completion = nil
        completion?(path)
    }

    // MARK: - Presentation

    /// Presents the panel as a sheet on `window`; `completion` receives the
    /// chosen absolute path, or nil on cancel. Fires exactly once.
    public func beginSheet(on window: NSWindow, completion: @escaping @MainActor (String?) -> Void) {
        self.completion = completion
        guard let sheet = self.window else {
            self.completion = nil
            completion(nil)
            return
        }
        window.beginSheet(sheet, completionHandler: nil)
    }
}
