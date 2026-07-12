// FileTreeSidebarView — Superlemon's native file-tree sidebar
// (NORTHSTAR §4.1 item 3, §5 "Sidebar", DESIGN §14.1).
//
// NSOutlineView-based, ~370 pt design width, 24 pt rows. The directory
// model is LAZY: a directory's children are listed only when the node is
// first expanded (never a whole-tree walk). File rows get a small colored
// type dot (swift orange / js yellow / md blue / json green / gray).
// Context menu: New File, New Folder, Rename, Delete (to Trash), Reveal in
// Finder — all emitted through `onFileOperation`; actual mutations happen
// in the embedder via `FileOperations`, followed by `reload(path:)`.
// Tree refreshes are explicit; there is currently no FSEvents watcher.

import AppKit

// MARK: - Directory listing abstraction (injectable for laziness tests)

public struct DirectoryEntry: Equatable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let isHidden: Bool

    public init(name: String, isDirectory: Bool, isHidden: Bool? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.isHidden = isHidden ?? name.hasPrefix(".")
    }
}

public protocol DirectoryLister {
    /// Immediate children of `url` (no recursion). Order is not required;
    /// the tree sorts directories-first, then case-insensitive by name.
    func list(_ url: URL) -> [DirectoryEntry]
}

public struct FileSystemLister: DirectoryLister {
    public init() {}

    public func list(_ url: URL) -> [DirectoryEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: []
        ) else { return [] }
        return urls.map { child in
            let values = try? child.resourceValues(forKeys: Set(keys))
            return DirectoryEntry(
                name: child.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                isHidden: values?.isHidden ?? child.lastPathComponent.hasPrefix(".")
            )
        }
    }
}

// MARK: - Lazy tree node

/// One row in the tree. Children are read through the lister on FIRST
/// access only (`childrenLoaded` flips), and can be invalidated for
/// subtree reloads. Main-thread-only (backs an NSOutlineView).
@MainActor
public final class FileTreeNode {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isHidden: Bool

    private var cachedChildren: [FileTreeNode]?
    public var childrenLoaded: Bool { cachedChildren != nil }

    public init(url: URL, isDirectory: Bool, isHidden: Bool? = nil) {
        self.url = url.standardizedFileURL
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isHidden = isHidden ?? url.lastPathComponent.hasPrefix(".")
    }

    /// Lazily lists children. `showHidden` filters dotfiles; `.git` is
    /// always hidden regardless.
    public func children(using lister: DirectoryLister, showHidden: Bool) -> [FileTreeNode] {
        guard isDirectory else { return [] }
        if cachedChildren == nil {
            cachedChildren = lister.list(url)
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                .map {
                    FileTreeNode(
                        url: url.appendingPathComponent($0.name),
                        isDirectory: $0.isDirectory,
                        isHidden: $0.isHidden
                    )
                }
        }
        let loaded = cachedChildren ?? []
        return showHidden
            ? loaded.filter { $0.name != ".git" }
            : loaded.filter { !$0.isHidden }
    }

    /// Drops the cached subtree so the next access re-lists from disk.
    public func invalidateChildren() { cachedChildren = nil }

    /// Depth-first search among LOADED nodes only (never triggers I/O).
    public func findLoadedNode(path: String) -> FileTreeNode? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if url.path == standardized { return self }
        guard standardized.hasPrefix(url.path + "/") else { return nil }
        for child in cachedChildren ?? [] {
            if let found = child.findLoadedNode(path: standardized) { return found }
        }
        return nil
    }
}

// MARK: - Sidebar view

@MainActor
public final class FileTreeSidebarView: NSView {

    public static let designWidth: CGFloat = 370
    public static let rowHeight: CGFloat = 24
    static let indentPerLevel: CGFloat = 17

    // Callbacks
    public var onOpenFile: ((String) -> Void)?
    /// Double-click: open as a permanent (pinned) buffer. Falls back to
    /// `onOpenFile` when unset.
    public var onOpenFilePermanently: ((String) -> Void)?

    /// Git badges (superlemon.git): absolute file path → one-letter status
    /// (M A D R C U ?). Directories containing a flagged file get a dot.
    private var gitStatuses: [String: String] = [:]
    private var gitDirtyDirs: Set<String> = []

    /// superlemon.ui sidebar decorations (runtime/CONTRACT.md), already
    /// COMPOSED across namespaces by the embedder: absolute path →
    /// decoration. Precedence rule: where a ui decoration and a git badge
    /// target the same path, the UI DECORATION WINS — explicit plugin
    /// intent outranks the built-in git provider. Built-in Git still uses its
    /// bespoke notification path (DESIGN §15). Paths without a ui decoration
    /// keep their git badge; `setGitStatus` keeps working unchanged.
    private var uiDecorations: [String: SidebarDecoration] = [:]

    /// Additive superlemon.ui entry point: replaces the full composed
    /// decoration map (keys are absolute paths). Coexists with
    /// `setGitStatus`; see `uiDecorations` for the precedence rule.
    public func setUIDecorations(_ decorations: [String: SidebarDecoration]) {
        uiDecorations = decorations
        outlineView.reloadData()
    }

    public func setGitStatus(_ statuses: [String: String]) {
        gitStatuses = statuses
        gitDirtyDirs = []
        let rootPath = rootNode?.url.path ?? "/"
        for path in statuses.keys {
            var dir = (path as NSString).deletingLastPathComponent
            while dir.count >= rootPath.count, dir != "/" {
                gitDirtyDirs.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        outlineView.reloadData()
    }

    static func gitBadge(status: String, dark: Bool) -> (text: String, color: NSColor) {
        switch status {
        case "M": return ("M", ShellPalette.gitModified(dark: dark))
        case "A": return ("A", ShellPalette.gitAdded(dark: dark))
        case "D": return ("D", ShellPalette.gitDeleted(dark: dark))
        case "R", "C": return ("R", ShellPalette.gitRenamed(dark: dark))
        case "U": return ("U", ShellPalette.gitDeleted(dark: dark))
        case "?": return ("?", ShellPalette.gitUntracked(dark: dark))
        default: return (status, ShellPalette.secondaryText(dark: dark))
        }
    }
    public var onFileOperation: ((FileOperation) -> Void)?

    /// Show dotfiles (`.git` stays hidden always).
    public var showsHiddenFiles: Bool = false {
        didSet { if showsHiddenFiles != oldValue { outlineView.reloadData() } }
    }

    public let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private(set) var rootNode: FileTreeNode?
    private let lister: DirectoryLister
    private var isDark = false

    /// - Parameter lister: directory-listing backend; tests inject a
    ///   counting wrapper to assert laziness.
    public init(frame frameRect: NSRect = .zero, lister: DirectoryLister = FileSystemLister()) {
        self.lister = lister
        super.init(frame: frameRect)
        setUp()
    }

    public required init?(coder: NSCoder) {
        self.lister = FileSystemLister()
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        wantsLayer = true

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowHeight = Self.rowHeight
        outlineView.indentationPerLevel = Self.indentPerLevel
        outlineView.intercellSpacing = .zero
        outlineView.selectionHighlightStyle = .regular
        outlineView.autoresizesOutlineColumn = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(rowClicked)
        outlineView.doubleAction = #selector(rowDoubleClicked)

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        applyAppearance(dark: false)
    }

    public func applyAppearance(dark: Bool) {
        isDark = dark
        layer?.backgroundColor = ShellPalette.surfaceBackground(dark: dark).cgColor
        outlineView.backgroundColor = .clear
        outlineView.reloadData()
    }

    // MARK: Root / reload

    /// Points the tree at a project root. Only the root's immediate
    /// children are listed (on first display) — the tree is lazy.
    public func setRoot(_ url: URL) {
        rootNode = FileTreeNode(url: url, isDirectory: true, isHidden: false)
        outlineView.reloadData()
    }

    /// Reloads a subtree after file operations. nil reloads the whole
    /// tree. Only re-lists directories that were already loaded.
    public func reload(path: String?) {
        guard let rootNode else { return }
        guard let path else {
            rootNode.invalidateChildren()
            outlineView.reloadData()
            return
        }
        guard let node = rootNode.findLoadedNode(path: path) else { return }
        let target = node.isDirectory ? node : rootNode.findLoadedNode(
            path: node.url.deletingLastPathComponent().path
        )
        guard let target else { return }
        target.invalidateChildren()
        if target === rootNode {
            outlineView.reloadData()
        } else {
            outlineView.reloadItem(target, reloadChildren: true)
        }
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        openRow(outlineView.clickedRow, isDoubleClick: false)
    }

    @objc private func rowDoubleClicked() {
        openRow(outlineView.clickedRow, isDoubleClick: true)
    }

    /// Single-click on a file fires `onOpenFile` (the app opens it as a
    /// PREVIEW — VS Code/Sublime semantics); double-click fires
    /// `onOpenFilePermanently` (promotes/pins). Directories toggle on
    /// double-click only.
    private func openRow(_ row: Int, isDoubleClick: Bool) {
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
        if node.isDirectory {
            guard isDoubleClick else { return }
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else if isDoubleClick {
            (onOpenFilePermanently ?? onOpenFile)?(node.url.path)
        } else {
            onOpenFile?(node.url.path)
        }
    }

    // MARK: Context-menu target

    fileprivate var contextMenuNode: FileTreeNode? {
        let row = outlineView.clickedRow
        guard row >= 0 else { return rootNode }
        return outlineView.item(atRow: row) as? FileTreeNode
    }

    @objc fileprivate func menuNewFile(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        onFileOperation?(.newFile(directory: dir.path, name: "untitled"))
    }

    @objc fileprivate func menuNewFolder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        onFileOperation?(.newFolder(directory: dir.path, name: "untitled folder"))
    }

    @objc fileprivate func menuRename(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        beginRename(of: node)
    }

    @objc fileprivate func menuDelete(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        onFileOperation?(.trash(path: node.url.path))
    }

    @objc fileprivate func menuReveal(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        onFileOperation?(.revealInFinder(path: node.url.path))
    }

    /// Puts the row's name label into edit mode; committing a changed name
    /// emits `.rename` through `onFileOperation`.
    public func beginRename(of node: FileTreeNode) {
        let row = outlineView.row(forItem: node)
        guard row >= 0,
              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? FileTreeCellView
        else { return }
        cell.beginEditing { [weak self] newName in
            guard let self, !newName.isEmpty, newName != node.name else { return }
            self.onFileOperation?(.rename(path: node.url.path, newName: newName))
        }
    }
}

// MARK: - Data source / delegate

extension FileTreeSidebarView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    private func node(for item: Any?) -> FileTreeNode? {
        item as? FileTreeNode ?? rootNode
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = node(for: item) else { return 0 }
        return node.children(using: lister, showHidden: showsHiddenFiles).count
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(for: item)!.children(using: lister, showHidden: showsHiddenFiles)[index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory ?? false
    }

    public func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        guard let node = item as? FileTreeNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileTreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil)
            as? FileTreeCellView ?? FileTreeCellView(identifier: identifier)
        cell.configure(node: node, dark: isDark)
        if let decoration = uiDecorations[node.url.path] {
            // superlemon.ui decoration wins over git for the same path.
            switch decoration.kind {
            case .badge(let text):
                cell.setGitBadge(
                    text,
                    color: decoration.color ?? ShellPalette.secondaryText(dark: isDark))
            case .dot:
                cell.setGitBadge(
                    "●",
                    color: decoration.color ?? ShellPalette.secondaryText(dark: isDark))
            }
        } else if node.isDirectory {
            if gitDirtyDirs.contains(node.url.path) {
                cell.setGitBadge("•", color: ShellPalette.gitModified(dark: isDark))
            }
        } else if let status = gitStatuses[node.url.path] {
            let badge = Self.gitBadge(status: status, dark: isDark)
            cell.setGitBadge(badge.text, color: badge.color)
        }
        return cell
    }

    public func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        FileTreeRowView(dark: isDark)
    }
}

// MARK: - Context menu construction

extension FileTreeSidebarView: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = contextMenuNode else { return }

        func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = node
            return item
        }

        menu.addItem(item("New File", #selector(menuNewFile(_:))))
        menu.addItem(item("New Folder", #selector(menuNewFolder(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Rename", #selector(menuRename(_:))))
        menu.addItem(item("Delete", #selector(menuDelete(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Reveal in Finder", #selector(menuReveal(_:))))
    }
}

// MARK: - Row / cell views

@MainActor
final class FileTreeRowView: NSTableRowView {
    private let dark: Bool

    init(dark: Bool) {
        self.dark = dark
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func drawSelection(in dirtyRect: NSRect) {
        // Full-width square-edged fill (#EAEAEA light / #343434 dark).
        ShellPalette.sidebarSelection(dark: dark).setFill()
        bounds.fill()
    }
}

@MainActor
final class FileTreeCellView: NSView {
    private let dotLabel = NSTextField(labelWithString: "●")
    private let nameLabel = NSTextField(labelWithString: "")
    private let gitBadgeLabel = NSTextField(labelWithString: "")
    private var commitHandler: ((String) -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        dotLabel.font = .systemFont(ofSize: 9)
        dotLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setAccessibilityIdentifier("sidebar.cell.name")
        nameLabel.delegate = self
        gitBadgeLabel.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        gitBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        gitBadgeLabel.setAccessibilityIdentifier("sidebar.cell.gitBadge")
        gitBadgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        gitBadgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(dotLabel)
        addSubview(nameLabel)
        addSubview(gitBadgeLabel)
        NSLayoutConstraint.activate([
            dotLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            // Fixed width so file names align whether the row shows a type
            // dot (files) or nothing (directories — the outline view's own
            // disclosure triangle is the only indicator).
            dotLabel.widthAnchor.constraint(equalToConstant: 12),
            dotLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.leadingAnchor.constraint(equalTo: dotLabel.trailingAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: gitBadgeLabel.leadingAnchor, constant: -4),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            gitBadgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            gitBadgeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(node: FileTreeNode, dark: Bool) {
        nameLabel.stringValue = node.name
        nameLabel.textColor = ShellPalette.primaryText(dark: dark)
        if node.isDirectory {
            // No glyph: the outline view's disclosure triangle already marks
            // directories — a second arrow here reads as a double chevron.
            dotLabel.stringValue = ""
        } else {
            dotLabel.stringValue = "●"
            dotLabel.textColor = ShellPalette.fileTypeColor(
                forExtension: node.url.pathExtension, dark: dark
            )
        }
        gitBadgeLabel.stringValue = ""  // reset; the sidebar re-applies per row
        endEditing(commit: false)
    }

    /// NERDTree-git-style trailing badge (M/A/D/R/?/• for dirty dirs).
    func setGitBadge(_ text: String, color: NSColor) {
        gitBadgeLabel.stringValue = text
        gitBadgeLabel.textColor = color
    }

    func beginEditing(onCommit: @escaping (String) -> Void) {
        commitHandler = onCommit
        nameLabel.isEditable = true
        nameLabel.isBezeled = true
        window?.makeFirstResponder(nameLabel)
        nameLabel.currentEditor()?.selectAll(nil)
    }

    private func endEditing(commit: Bool) {
        guard nameLabel.isEditable else { return }
        let handler = commitHandler
        commitHandler = nil
        nameLabel.isEditable = false
        nameLabel.isBezeled = false
        if commit { handler?(nameLabel.stringValue) }
    }
}

extension FileTreeCellView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        endEditing(commit: true)
    }
}
