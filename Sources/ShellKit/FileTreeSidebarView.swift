// FileTreeSidebarView — Superlemon's native file-tree sidebar
// (NORTHSTAR §4.1 item 3, §5 "Sidebar", DESIGN §14.1).
//
// NSOutlineView-based, ~370 pt design width, 24 pt rows. The directory
// model is LAZY: a directory's children are listed only when the node is
// first expanded (never a whole-tree walk). File rows get a small colored
// type dot (swift orange / js yellow / md blue / json green / gray).
// Context menu: New File, New Folder, Rename, Move to Trash, Reveal in
// Finder — all emitted through `onFileOperation`; actual mutations happen
// in the embedder via `FileOperations`, followed by `reload(path:)`.
// WorkspaceChrome refreshes this lazy model from a debounced FSEvents watcher.

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

public protocol DirectoryLister: Sendable {
    /// Immediate children of `url` (no recursion). Order is not required;
    /// the tree sorts directories-first, then case-insensitive by name.
    /// May suspend: a session-backed lister fetches the listing over RPC
    /// from the filesystem the connected editor sees.
    func list(_ url: URL) async throws -> [DirectoryEntry]
}

public struct FileSystemLister: DirectoryLister {
    public init() {}

    public func list(_ url: URL) async throws -> [DirectoryEntry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let urls = try fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])
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

public enum FileTreeLoadState: Equatable, Sendable {
    case unloaded
    case loading
    case loaded
    case failed(String)
}

public enum FileTreeCreateKind: Equatable, Sendable {
    case file
    case folder
}

private enum DirectoryListingResult: Sendable {
    case success([DirectoryEntry])
    case failure(String)
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

    private var cachedChildren: [FileTreeNode] = []
    public private(set) var loadState: FileTreeLoadState = .unloaded
    public var childrenLoaded: Bool { loadState == .loaded }
    fileprivate lazy var placeholder = FileTreePlaceholder(parent: self)

    public init(url: URL, isDirectory: Bool, isHidden: Bool? = nil) {
        self.url = url.standardizedFileURL
        self.name = url.lastPathComponent
        self.isDirectory = isDirectory
        self.isHidden = isHidden ?? url.lastPathComponent.hasPrefix(".")
    }

    /// Lazily lists children. `showHidden` filters dotfiles; `.git` is
    /// always hidden regardless.
    public func children(using lister: DirectoryLister, showHidden: Bool) async -> [FileTreeNode] {
        guard isDirectory else { return [] }
        if !childrenLoaded {
            beginLoading()
            do {
                installChildren(try await lister.list(url))
            } catch {
                failLoading(error.localizedDescription)
            }
        }
        return loadedChildren(showHidden: showHidden) ?? []
    }

    public func beginLoading() {
        guard isDirectory else { return }
        loadState = .loading
    }

    /// Installs entries that were listed away from the main actor. Node/view
    /// creation remains on the main actor, but the blocking filesystem call
    /// does not.
    public func installChildren(_ entries: [DirectoryEntry]) {
        cachedChildren = makeChildren(from: entries, reusing: [:])
        loadState = .loaded
    }

    /// Reconciles a refreshed one-level listing without replacing unchanged
    /// nodes. Keeping node identity is what lets NSOutlineView retain loaded
    /// descendants, expansion state, and selection across filesystem events.
    /// No descendant is listed or invalidated here.
    func reconcileChildren(_ entries: [DirectoryEntry]) {
        let existing = Dictionary(
            uniqueKeysWithValues: cachedChildren.map {
                (ChildIdentity(path: $0.url.path, isDirectory: $0.isDirectory), $0)
            })
        cachedChildren = makeChildren(from: entries, reusing: existing)
        loadState = .loaded
    }

    private struct ChildIdentity: Hashable {
        let path: String
        let isDirectory: Bool
    }

    private func makeChildren(
        from entries: [DirectoryEntry],
        reusing existing: [ChildIdentity: FileTreeNode]
    ) -> [FileTreeNode] {
        entries
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            .map { entry in
                let childURL = url.appendingPathComponent(entry.name).standardizedFileURL
                let identity = ChildIdentity(
                    path: childURL.path, isDirectory: entry.isDirectory)
                return existing[identity] ?? FileTreeNode(
                    url: childURL,
                    isDirectory: entry.isDirectory,
                    isHidden: entry.isHidden
                )
            }
    }

    public func failLoading(_ description: String) {
        cachedChildren = []
        loadState = .failed(description)
    }

    /// Reads the already-loaded cache only; returns nil until a listing has
    /// completed. This is the production outline-view data-source path.
    public func loadedChildren(showHidden: Bool) -> [FileTreeNode]? {
        guard loadState == .loaded else { return nil }
        return showHidden
            ? cachedChildren.filter { $0.name != ".git" }
            : cachedChildren.filter { !$0.isHidden }
    }

    /// Drops the cached subtree so the next access re-lists from disk.
    public func invalidateChildren() {
        cachedChildren = []
        loadState = .unloaded
    }

    /// Depth-first search among LOADED nodes only (never triggers I/O).
    public func findLoadedNode(path: String) -> FileTreeNode? {
        loadedNodeChain(path: path)?.last
    }

    fileprivate func loadedNodeChain(path: String) -> [FileTreeNode]? {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if url.path == standardized { return [self] }
        guard standardized.hasPrefix(url.path + "/") else { return nil }
        for child in cachedChildren {
            if let chain = child.loadedNodeChain(path: standardized) {
                return [self] + chain
            }
        }
        return nil
    }

    /// Visits represented nodes using only the in-memory cache. This must
    /// never trigger directory enumeration: layout snapshots rely on it while
    /// applying an FSEvents refresh on the main actor.
    fileprivate func forEachRepresentedNode(_ body: (FileTreeNode) -> Void) {
        body(self)
        for child in cachedChildren {
            child.forEachRepresentedNode(body)
        }
    }
}

@MainActor
private final class FileTreePlaceholder {
    unowned let parent: FileTreeNode
    init(parent: FileTreeNode) { self.parent = parent }
}

/// Synthetic ".." row shown above the root's children: clicking it changes
/// the working directory to the root's parent. Deliberately not a
/// FileTreeNode so expansion/refresh/layout logic (which casts to
/// FileTreeNode) ignores it by construction. One fresh instance per root
/// keeps outline-item identity from leaking across re-roots.
@MainActor
private final class FileTreeParentDirectoryEntry {}

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
    /// Called after an action that hands editing back to Neovim. Embedders use
    /// this instead of leaving keyboard focus stranded in the outline view.
    public var onRequestEditorFocus: (() -> Void)?
    /// Requests a naming UI for a new item. The sidebar deliberately does
    /// not invent a hard-coded filename; the embedder validates and performs
    /// the resulting mutation.
    public var onRequestCreateItem: ((String, FileTreeCreateKind) -> Void)?
    /// Fired with an absolute directory path when the user asks to re-root
    /// the workspace there (the ".." row or a folder's context menu). The
    /// embedder performs the cd (through nvim) and calls `setRoot` back.
    public var onChangeWorkingDirectory: ((String) -> Void)?

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
        reloadAllRowsPreservingLayout()
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
        reloadAllRowsPreservingLayout()
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

    /// Whether rows offer local-filesystem affordances (the context menu's
    /// New File/Folder, Rename, Move to Trash, and Reveal in Finder). Turned
    /// off when the tree is sourced from a filesystem this machine's
    /// FileManager and Finder cannot reach (remote sessions).
    public var allowsFileOperations = true

    /// Refresh a loaded directory every time it is expanded, not only when a
    /// filesystem event marked it stale. Trees sourced without change
    /// notifications (a remote filesystem has no FSEvents equivalent) use
    /// this as a cheap poll on expansion.
    public var refreshesOnExpand = false

    // MARK: Drag & drop (WorkspaceFileTransfer.swift)

    /// External drop: local file URLs land in a workspace directory. The
    /// embedder runs the transfer (local copy or RPC upload). Unset
    /// disables drops.
    public var onDropFiles: ((_ urls: [URL], _ directoryPath: String) -> Void)?
    /// Internal drag between tree directories: a MOVE within the workspace.
    /// Unset disables internal drags.
    public var onMoveItems: ((_ sourcePaths: [String], _ directoryPath: String) -> Void)?
    /// Pasteboard writer for dragging a row OUT of the tree: a plain file
    /// URL when the workspace is this machine's filesystem (Finder performs
    /// the copy), or an NSFilePromiseProvider whose fulfillment streams a
    /// download. Unset disables dragging out.
    public var dragWriterProvider: ((_ path: String, _ isDirectory: Bool) -> NSPasteboardWriting?)?
    /// Cancel button in the transfer band.
    public var onCancelTransfers: (() -> Void)? {
        get { transferBand.onCancel }
        set { transferBand.onCancel = newValue }
    }

    /// Paths captured at drag start; internal drops consume these instead
    /// of round-tripping through the pasteboard (a remote tree's writers
    /// are promises, not URLs).
    var draggedNodePaths: [String] = []
    private let transferBand = FileTransferProgressView()
    private var transferBandHeight: NSLayoutConstraint!
    private let promiseReceiveQueue = OperationQueue()

    /// Show dotfiles (`.git` stays hidden always).
    public var showsHiddenFiles: Bool = false {
        didSet {
            if showsHiddenFiles != oldValue { reloadAllRowsPreservingLayout() }
        }
    }

    public let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private(set) var rootNode: FileTreeNode?
    private var parentEntry: FileTreeParentDirectoryEntry?
    /// The ".." row shows whenever the root has a parent to go up to.
    private var showsParentEntry: Bool {
        guard let rootNode else { return false }
        return rootNode.url.path != "/"
    }
    private let lister: DirectoryLister
    private var isDark = false
    private var treeGeneration: UInt64 = 0
    private var loadingTasks: [String: Task<Void, Never>] = [:]
    private var loadingTokens: [String: UInt64] = [:]
    private var nextLoadingToken: UInt64 = 0
    private var pendingExpansionPaths: Set<String> = []
    private var staleDirectoryPaths: Set<String> = []
    private var isRestoringLayout = false

    private struct LayoutSnapshot {
        let expandedPaths: [String]
        let selectedPath: String?
        let scrollOrigin: NSPoint
        let scrollAnchorPath: String?
        let scrollAnchorOffset: CGFloat
    }

    private enum ListingPurpose {
        case initial
        case refresh
    }

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

        // Dragging: rows drag out (writer supplied by the embedder), Finder
        // items and file promises drop in, and rows move between the tree's
        // own directories.
        var draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]
        draggedTypes += NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
        outlineView.registerForDraggedTypes(draggedTypes)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        // In-app drags cover BOTH cases: a move within this tree and a copy
        // into a sibling editor pane's tree (which is a different outline
        // view, so it validates as an external .copy drop).
        outlineView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        transferBand.translatesAutoresizingMaskIntoConstraints = false
        transferBand.isHidden = true
        addSubview(transferBand)
        transferBandHeight = transferBand.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: transferBand.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            transferBand.leadingAnchor.constraint(equalTo: leadingAnchor),
            transferBand.trailingAnchor.constraint(equalTo: trailingAnchor),
            transferBand.bottomAnchor.constraint(equalTo: bottomAnchor),
            transferBandHeight,
        ])

        applyAppearance(dark: false)
    }

    /// Shows/updates the bottom transfer band; nil collapses it.
    public func renderTransferProgress(_ progress: WorkspaceTransferProgress?) {
        guard let progress else {
            transferBandHeight.constant = 0
            transferBand.isHidden = true
            return
        }
        transferBand.render(progress)
        if transferBand.isHidden {
            transferBandHeight.constant = FileTransferProgressView.bandHeight
            transferBand.isHidden = false
        }
    }

    public func applyAppearance(dark: Bool) {
        isDark = dark
        layer?.backgroundColor = ShellPalette.surfaceBackground(dark: dark).cgColor
        outlineView.backgroundColor = .clear
        transferBand.applyAppearance(dark: dark)
        reloadAllRowsPreservingLayout()
    }

    // MARK: Root / reload

    /// Points the tree at a project root. Only the root's immediate
    /// children are listed (on first display) — the tree is lazy.
    public func setRoot(_ url: URL) {
        treeGeneration &+= 1
        for task in loadingTasks.values { task.cancel() }
        loadingTasks.removeAll()
        loadingTokens.removeAll()
        pendingExpansionPaths.removeAll()
        staleDirectoryPaths.removeAll()
        rootNode = FileTreeNode(url: url, isDirectory: true, isHidden: false)
        parentEntry = FileTreeParentDirectoryEntry()
        outlineView.reloadData()
        if let rootNode { requestChildren(for: rootNode) }
    }

    /// Reloads a directory after an explicit file operation. A refresh keeps
    /// the existing rows visible until the detached listing completes, then
    /// reconciles one level by path so unchanged subtrees retain identity.
    /// `nil` is the recovery/root-refresh path and preserves layout as well.
    public func reload(path: String?) {
        guard let rootNode else { return }
        guard let path else {
            enqueueRefresh(of: rootNode)
            return
        }
        guard let node = rootNode.findLoadedNode(path: path) else { return }
        let target = node.isDirectory ? node : rootNode.findLoadedNode(
            path: node.url.deletingLastPathComponent().path
        )
        guard let target else { return }
        enqueueRefresh(of: target)
    }

    /// Applies an FSEvents batch to the smallest represented directory for
    /// each changed path. Duplicate targets are listed once. A represented
    /// but collapsed directory is marked stale and is not enumerated until
    /// the user expands it; an unloaded directory already has no stale cache.
    public func reload(
        changedPaths: Set<String>,
        requiresFullRescan: Bool = false
    ) {
        if requiresFullRescan {
            refreshAllRepresentedDirectories()
            return
        }
        guard !changedPaths.isEmpty else { return }
        var targets: [String: FileTreeNode] = [:]
        for path in changedPaths {
            guard let target = nearestRepresentedDirectory(forChangedPath: path) else {
                continue
            }
            switch target.loadState {
            case .loaded where isVisibleForRefresh(target):
                targets[target.url.path] = target
            case .loaded:
                staleDirectoryPaths.insert(target.url.path)
            case .unloaded, .loading, .failed:
                // An unloaded branch will read the current filesystem state
                // on first expansion. Never force I/O into a collapsed branch.
                break
            }
        }
        for target in targets.values {
            requestRefresh(for: target)
        }
    }

    /// FSEvents explicitly reports when its per-path history is incomplete.
    /// Refresh every visible loaded directory and mark hidden loaded branches
    /// stale for their next expansion; never force I/O into unloaded branches.
    private func refreshAllRepresentedDirectories() {
        var targets: [FileTreeNode] = []
        rootNode?.forEachRepresentedNode { [weak self] node in
            guard let self, node.isDirectory else { return }
            switch node.loadState {
            case .loaded where self.isVisibleForRefresh(node):
                targets.append(node)
            case .loaded:
                self.staleDirectoryPaths.insert(node.url.path)
            case .unloaded, .loading, .failed:
                break
            }
        }
        for target in targets { requestRefresh(for: target) }
    }

    /// Finds the deepest represented ancestor whose immediate child listing
    /// could contain the changed path. This walks cached nodes only.
    private func nearestRepresentedDirectory(forChangedPath path: String) -> FileTreeNode? {
        guard let rootNode else { return nil }
        let rootPath = rootNode.url.path
        let changedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard isPath(changedPath, inside: rootPath) else {
            return nil
        }
        if changedPath == rootPath { return rootNode }

        var probe = URL(fileURLWithPath: changedPath)
            .deletingLastPathComponent().standardizedFileURL.path
        while isPath(probe, inside: rootPath) {
            if let candidate = rootNode.findLoadedNode(path: probe) {
                return candidate.isDirectory ? candidate : nil
            }
            guard probe != rootPath else { break }
            let parent = URL(fileURLWithPath: probe)
                .deletingLastPathComponent().standardizedFileURL.path
            guard parent != probe else { break }
            probe = parent
        }
        return nil
    }

    private func isPath(_ path: String, inside rootPath: String) -> Bool {
        path == rootPath
            || (rootPath == "/" ? path.hasPrefix("/") : path.hasPrefix(rootPath + "/"))
    }

    private func isVisibleForRefresh(_ node: FileTreeNode) -> Bool {
        if node === rootNode { return true }
        return outlineView.row(forItem: node) >= 0 && outlineView.isItemExpanded(node)
    }

    private func enqueueRefresh(of node: FileTreeNode) {
        switch node.loadState {
        case .loaded where isVisibleForRefresh(node):
            requestRefresh(for: node)
        case .loaded:
            staleDirectoryPaths.insert(node.url.path)
        case .failed where node === rootNode:
            retryLoading(node)
        case .unloaded, .loading, .failed:
            break
        }
    }

    /// Test/diagnostic hook: waits for directory reads already in flight.
    public func waitForPendingLoads() async {
        while !loadingTasks.isEmpty {
            for task in Array(loadingTasks.values) { await task.value }
        }
    }

    /// Selects an item that is already represented by the loaded tree and
    /// scrolls it into view. Used after successful create operations.
    @discardableResult
    public func selectItem(path: String, focus: Bool = false) -> Bool {
        guard let chain = rootNode?.loadedNodeChain(path: path),
            let node = chain.last
        else { return false }
        for ancestor in chain.dropFirst().dropLast() where ancestor.isDirectory {
            outlineView.expandItem(ancestor)
        }
        outlineView.layoutSubtreeIfNeeded()
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return false }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        if focus { window?.makeFirstResponder(outlineView) }
        return true
    }

    /// Makes a newly-created item visible even when its represented parent
    /// was collapsed or had never been enumerated. Only that parent is read:
    /// unrelated branches keep their node identity and expansion state.
    ///
    /// Call this only after the filesystem mutation succeeds. Directory
    /// listing remains detached from the main actor through `scheduleListing`.
    @discardableResult
    public func revealCreatedItem(path: String, focus: Bool = false) async -> Bool {
        guard let rootNode else { return false }
        let targetPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard targetPath != rootNode.url.path,
            isPath(targetPath, inside: rootNode.url.path)
        else { return false }

        let parentPath = URL(fileURLWithPath: targetPath)
            .deletingLastPathComponent().standardizedFileURL.path
        guard let parent = rootNode.findLoadedNode(path: parentPath),
            parent.isDirectory
        else { return false }

        // If an initial read was already in flight before creation, its
        // snapshot may predate the mutation. Follow it with one authoritative
        // refresh. Reads started here happen after creation and need no second
        // enumeration.
        let needsRefreshAfterCurrentLoad: Bool
        switch parent.loadState {
        case .loaded:
            needsRefreshAfterCurrentLoad = false
            requestRefresh(for: parent)
        case .unloaded:
            needsRefreshAfterCurrentLoad = false
            requestChildren(for: parent)
        case .loading:
            needsRefreshAfterCurrentLoad = true
        case .failed:
            needsRefreshAfterCurrentLoad = false
            retryLoading(parent)
        }
        await waitForPendingLoad(at: parentPath)

        if case .failed = parent.loadState {
            retryLoading(parent)
            await waitForPendingLoad(at: parentPath)
        } else if needsRefreshAfterCurrentLoad, parent.loadState == .loaded {
            requestRefresh(for: parent)
            await waitForPendingLoad(at: parentPath)
        }

        guard parent.loadState == .loaded else { return false }
        staleDirectoryPaths.remove(parentPath)
        return selectItem(path: targetPath, focus: focus)
    }

    private func waitForPendingLoad(at path: String) async {
        while let task = loadingTasks[path] { await task.value }
    }

    /// Restores a failed inline rename from the immutable node model. The
    /// text field is edited optimistically, but the filesystem remains the
    /// source of truth until the embedder reports mutation success.
    @discardableResult
    public func rollbackInlineRename(path: String) -> Bool {
        guard let node = rootNode?.findLoadedNode(path: path) else { return false }
        outlineView.reloadItem(node)
        return true
    }

    private func requestChildren(for node: FileTreeNode) {
        guard node.isDirectory, node.loadState == .unloaded,
            loadingTasks[node.url.path] == nil
        else { return }

        scheduleListing(for: node, purpose: .initial)
    }

    private func requestRefresh(for node: FileTreeNode) {
        guard node.isDirectory, node.loadState == .loaded else { return }
        if let existing = loadingTasks[node.url.path] {
            existing.cancel()
            loadingTasks[node.url.path] = nil
            loadingTokens[node.url.path] = nil
        }
        staleDirectoryPaths.remove(node.url.path)
        scheduleListing(for: node, purpose: .refresh)
    }

    private func scheduleListing(for node: FileTreeNode, purpose: ListingPurpose) {
        let path = node.url.path
        guard loadingTasks[path] == nil else { return }
        if purpose == .initial { node.beginLoading() }

        let url = node.url
        let lister = self.lister
        let generation = treeGeneration
        nextLoadingToken &+= 1
        let token = nextLoadingToken
        loadingTokens[path] = token
        loadingTasks[path] = Task { [weak self, weak node] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return DirectoryListingResult.success(try await lister.list(url))
                } catch {
                    return DirectoryListingResult.failure(error.localizedDescription)
                }
            }.value
            let wasCancelled = Task.isCancelled
            guard let self, self.loadingTokens[path] == token else { return }
            self.loadingTasks[path] = nil
            self.loadingTokens[path] = nil
            guard !wasCancelled, let node, self.treeGeneration == generation,
                self.rootNode?.findLoadedNode(path: path) === node
            else { return }

            switch purpose {
            case .initial:
                switch result {
                case .success(let entries):
                    node.installChildren(entries)
                case .failure(let description):
                    node.failLoading(description)
                }
                let shouldExpand = self.pendingExpansionPaths.remove(path) != nil
                if node === self.rootNode {
                    self.outlineView.reloadData()
                } else {
                    self.outlineView.reloadItem(node, reloadChildren: true)
                    if shouldExpand {
                        // Programmatic follow-through of the user's expansion,
                        // whose listing just arrived: it must not read as a
                        // fresh user expand (poll-on-expand would immediately
                        // re-list, doubling every first remote expansion).
                        self.isRestoringLayout = true
                        defer { self.isRestoringLayout = false }
                        self.outlineView.expandItem(node)
                    }
                }
            case .refresh:
                guard case .success(let entries) = result else {
                    // A transient refresh failure must not erase a working,
                    // already-loaded subtree.
                    self.staleDirectoryPaths.insert(path)
                    return
                }
                let layout = self.captureLayout()
                node.reconcileChildren(entries)
                self.pruneStaleDirectories()
                self.isRestoringLayout = true
                defer { self.isRestoringLayout = false }
                if node === self.rootNode {
                    self.outlineView.reloadData()
                } else {
                    self.outlineView.reloadItem(node, reloadChildren: true)
                }
                self.restoreLayout(layout)
            }
        }
    }

    private func captureLayout() -> LayoutSnapshot {
        var expandedPaths: [String] = []
        rootNode?.forEachRepresentedNode { [outlineView, rootNode] node in
            guard node !== rootNode, node.isDirectory,
                outlineView.isItemExpanded(node)
            else { return }
            expandedPaths.append(node.url.path)
        }
        let selectedPath = (outlineView.item(atRow: outlineView.selectedRow)
            as? FileTreeNode)?.url.path
        let scrollOrigin = scrollView.contentView.bounds.origin
        let anchorRow = outlineView.row(at: NSPoint(
            x: outlineView.bounds.midX, y: scrollOrigin.y + 1))
        let anchorNode = anchorRow >= 0
            ? outlineView.item(atRow: anchorRow) as? FileTreeNode
            : nil
        let anchorOffset = anchorRow >= 0
            ? scrollOrigin.y - outlineView.rect(ofRow: anchorRow).minY
            : 0
        return LayoutSnapshot(
            expandedPaths: expandedPaths,
            selectedPath: selectedPath,
            scrollOrigin: scrollOrigin,
            scrollAnchorPath: anchorNode?.url.path,
            scrollAnchorOffset: anchorOffset)
    }

    private func restoreLayout(_ layout: LayoutSnapshot) {
        for path in layout.expandedPaths.sorted(by: {
            $0.split(separator: "/").count < $1.split(separator: "/").count
        }) {
            guard let node = rootNode?.findLoadedNode(path: path),
                node.isDirectory, node.loadState == .loaded
            else { continue }
            outlineView.expandItem(node)
        }
        outlineView.layoutSubtreeIfNeeded()
        if let selectedPath = layout.selectedPath,
            let selectedNode = rootNode?.findLoadedNode(path: selectedPath)
        {
            let row = outlineView.row(forItem: selectedNode)
            if row >= 0 {
                outlineView.selectRowIndexes(
                    IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        outlineView.layoutSubtreeIfNeeded()
        var restoredOrigin = layout.scrollOrigin
        if let anchorPath = layout.scrollAnchorPath,
            let anchor = rootNode?.findLoadedNode(path: anchorPath)
        {
            let row = outlineView.row(forItem: anchor)
            if row >= 0 {
                restoredOrigin.y = outlineView.rect(ofRow: row).minY
                    + layout.scrollAnchorOffset
            }
        }
        scrollView.contentView.scroll(to: restoredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func reloadAllRowsPreservingLayout() {
        guard rootNode != nil else {
            outlineView.reloadData()
            return
        }
        let layout = captureLayout()
        isRestoringLayout = true
        defer { isRestoringLayout = false }
        outlineView.reloadData()
        restoreLayout(layout)
    }

    private func pruneStaleDirectories() {
        staleDirectoryPaths = Set(staleDirectoryPaths.filter {
            rootNode?.findLoadedNode(path: $0) != nil
        })
    }

    private func refreshVisibleStaleDirectories() {
        for path in Array(staleDirectoryPaths) {
            guard let node = rootNode?.findLoadedNode(path: path),
                node.loadState == .loaded, isVisibleForRefresh(node)
            else { continue }
            requestRefresh(for: node)
        }
    }

    private func retryLoading(_ node: FileTreeNode) {
        guard case .failed = node.loadState else { return }
        node.invalidateChildren()
        if node === rootNode {
            outlineView.reloadData()
        } else {
            outlineView.reloadItem(node, reloadChildren: true)
        }
        requestChildren(for: node)
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        performRowAction(row: outlineView.clickedRow, isDoubleClick: false)
    }

    @objc private func rowDoubleClicked() {
        performRowAction(row: outlineView.clickedRow, isDoubleClick: true)
    }

    /// Single-click on a file fires `onOpenFile` (the app opens it as a
    /// PREVIEW — VS Code/Sublime semantics); double-click fires
    /// `onOpenFilePermanently` (promotes/pins). Directories toggle on
    /// double-click only.
    func performRowAction(row: Int, isDoubleClick: Bool) {
        guard row >= 0 else { return }
        if outlineView.item(atRow: row) is FileTreeParentDirectoryEntry {
            defer { onRequestEditorFocus?() }
            guard let rootNode else { return }
            onChangeWorkingDirectory?(
                rootNode.url.deletingLastPathComponent().path)
            return
        }
        guard let node = outlineView.item(atRow: row) as? FileTreeNode else { return }
        defer { onRequestEditorFocus?() }
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
        onRequestCreateItem?(dir.path, .file)
    }

    @objc fileprivate func menuNewFolder(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        let dir = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        onRequestCreateItem?(dir.path, .folder)
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

    @objc fileprivate func menuChangeWorkingDirectory(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? FileTreeNode else { return }
        onChangeWorkingDirectory?(node.url.path)
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
            guard let self else { return }
            if !newName.isEmpty, newName != node.name {
                self.onFileOperation?(.rename(path: node.url.path, newName: newName))
            }
            self.onRequestEditorFocus?()
        }
    }
}

// MARK: - Data source / delegate

extension FileTreeSidebarView: NSOutlineViewDataSource, NSOutlineViewDelegate {

    private func node(for item: Any?) -> FileTreeNode? {
        item == nil ? rootNode : item as? FileTreeNode
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = node(for: item) else { return 0 }
        // The synthetic ".." row occupies index 0 of the root level.
        let parentRows = item == nil && showsParentEntry ? 1 : 0
        switch node.loadState {
        case .unloaded:
            requestChildren(for: node)
            return parentRows + 1
        case .loading, .failed:
            return parentRows + 1
        case .loaded:
            return parentRows
                + (node.loadedChildren(showHidden: showsHiddenFiles)?.count ?? 0)
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        var index = index
        if item == nil, showsParentEntry {
            if index == 0 { return parentEntry! }
            index -= 1
        }
        let node = node(for: item)!
        if let children = node.loadedChildren(showHidden: showsHiddenFiles) {
            return children[index]
        }
        precondition(index == 0)
        return node.placeholder
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.isDirectory ?? false
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FileTreeNode else { return false }
        if !isRestoringLayout { onRequestEditorFocus?() }
        if !node.childrenLoaded {
            pendingExpansionPaths.insert(node.url.path)
            requestChildren(for: node)
        } else if staleDirectoryPaths.remove(node.url.path) != nil
            || (refreshesOnExpand && !isRestoringLayout)
        {
            // A collapsed loaded branch stayed untouched while FSEvents were
            // arriving. Refresh only now that it is becoming visible. The
            // poll-on-expand mode must ignore restoreLayout's re-expansions:
            // a refresh completion restores layout, so polling there would
            // schedule the next refresh forever.
            requestRefresh(for: node)
        }
        return true
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        if let node = item as? FileTreeNode {
            pendingExpansionPaths.remove(node.url.path)
            if !isRestoringLayout { onRequestEditorFocus?() }
        }
        return true
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        // Descendants can remain logically expanded while an ancestor is
        // collapsed. Once that ancestor opens, refresh any now-visible stale
        // descendants without touching their still-collapsed siblings.
        refreshVisibleStaleDirectories()
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard outlineView.selectedRow >= 0 else { return }
        if !isRestoringLayout { onRequestEditorFocus?() }
    }

    public func outlineView(
        _ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any
    ) -> NSView? {
        if let placeholder = item as? FileTreePlaceholder {
            let identifier = NSUserInterfaceItemIdentifier("FileTreePlaceholderCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil)
                as? FileTreePlaceholderCellView
                ?? FileTreePlaceholderCellView(identifier: identifier)
            cell.configure(state: placeholder.parent.loadState) { [weak self, weak parent = placeholder.parent] in
                guard let parent else { return }
                self?.retryLoading(parent)
            }
            return cell
        }
        if item is FileTreeParentDirectoryEntry {
            let identifier = NSUserInterfaceItemIdentifier("FileTreeParentCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil)
                as? FileTreeCellView ?? FileTreeCellView(identifier: identifier)
            let parentPath = rootNode?.url.deletingLastPathComponent().path ?? "/"
            cell.configureAsParentDirectory(parentPath: parentPath, dark: isDark)
            return cell
        }
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

    // MARK: Drag source

    public func outlineView(
        _ outlineView: NSOutlineView, pasteboardWriterForItem item: Any
    ) -> NSPasteboardWriting? {
        guard let node = item as? FileTreeNode, node !== rootNode else { return nil }
        return dragWriterProvider?(node.url.path, node.isDirectory)
    }

    public func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
        draggedNodePaths = draggedItems.compactMap { ($0 as? FileTreeNode)?.url.path }
    }

    public func outlineView(
        _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        draggedNodePaths = []
    }

    // MARK: Drop target

    /// Any row is a valid landing spot: a directory receives directly, a
    /// file forwards to its parent, and the empty area targets the root.
    /// Internal for tests (NSDraggingInfo cannot be constructed headless).
    func dropTargetDirectory(for item: Any?) -> FileTreeNode? {
        guard let node = (item as? FileTreeNode) ?? rootNode else { return nil }
        if node.isDirectory { return node }
        return node === rootNode
            ? node
            : rootNode?.findLoadedNode(path: node.url.deletingLastPathComponent().path)
    }

    private func isInternalDrag(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSOutlineView) === outlineView
    }

    /// Paths that actually change parent, excluding drops into a dragged
    /// item's own subtree. Internal for tests.
    func movablePaths(into directory: String) -> [String] {
        guard !draggedNodePaths.contains(where: {
            directory == $0 || directory.hasPrefix($0 + "/")
        }) else { return [] }
        return draggedNodePaths.filter {
            ($0 as NSString).deletingLastPathComponent != directory
        }
    }

    public func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
        proposedItem item: Any?, proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let target = dropTargetDirectory(for: item) else { return [] }
        outlineView.setDropItem(
            target === rootNode ? nil : target,
            dropChildIndex: NSOutlineViewDropOnItemIndex)
        if isInternalDrag(info) {
            guard onMoveItems != nil, !movablePaths(into: target.url.path).isEmpty else {
                return []
            }
            return .move
        }
        guard onDropFiles != nil else { return [] }
        let pasteboard = info.draggingPasteboard
        let hasFiles =
            pasteboard.canReadObject(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
        return hasFiles ? .copy : []
    }

    public func outlineView(
        _ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
        item: Any?, childIndex index: Int
    ) -> Bool {
        guard let target = dropTargetDirectory(for: item) else { return false }
        let directory = target.url.path
        if isInternalDrag(info) {
            let paths = movablePaths(into: directory)
            guard !paths.isEmpty else { return false }
            onMoveItems?(paths, directory)
            return true
        }
        let pasteboard = info.draggingPasteboard
        if let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self])
            as? [NSFilePromiseReceiver], !receivers.isEmpty
        {
            receivePromisedFiles(receivers, into: directory)
            return true
        }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            !urls.isEmpty
        {
            onDropFiles?(urls, directory)
            return true
        }
        return false
    }

    /// Promise-based drags (Photos, Mail, another Superlemon's remote tree)
    /// materialize in a private staging directory first, then enter the
    /// normal dropped-URL flow.
    private func receivePromisedFiles(
        _ receivers: [NSFilePromiseReceiver], into directory: String
    ) {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-promised-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)
        let lock = NSLock()
        nonisolated(unsafe) var received: [URL] = []
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: staging, options: [:], operationQueue: promiseReceiveQueue
            ) { url, error in
                guard error == nil else { return }
                lock.withLock { received.append(url) }
            }
        }
        promiseReceiveQueue.addBarrierBlock { [weak self] in
            let urls = lock.withLock { received }
            guard !urls.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.onDropFiles?(urls, directory)
            }
        }
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

        // Re-rooting goes through nvim's cwd, not the local filesystem, so
        // it stays available for remote-sourced trees. The root itself is
        // excluded (a cd to the current root is a no-op; ".." goes up).
        if node.isDirectory, node !== rootNode {
            menu.addItem(
                item(
                    "Set as Working Directory",
                    #selector(menuChangeWorkingDirectory(_:))))
        }

        // Every remaining item mutates or reveals through the LOCAL
        // filesystem; an empty menu never shows, so remote-sourced trees get
        // only the re-root affordance (or no menu at all on files).
        guard allowsFileOperations else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }

        menu.addItem(item("New File", #selector(menuNewFile(_:))))
        menu.addItem(item("New Folder", #selector(menuNewFolder(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Rename", #selector(menuRename(_:))))
        menu.addItem(item("Move to Trash", #selector(menuDelete(_:))))
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
private final class FileTreePlaceholderCellView: NSView {
    private let spinner = NSProgressIndicator()
    private let messageLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var onRetry: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setAccessibilityLabel("Loading folder")

        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton.bezelStyle = .inline
        retryButton.controlSize = .small
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(spinner)
        addSubview(messageLabel)
        addSubview(retryButton)
        NSLayoutConstraint.activate([
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            messageLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 5),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: messageLabel.trailingAnchor, constant: 6),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(state: FileTreeLoadState, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        switch state {
        case .unloaded, .loading:
            spinner.isHidden = false
            spinner.startAnimation(nil)
            messageLabel.stringValue = "Loading…"
            messageLabel.toolTip = nil
            retryButton.isHidden = true
        case .failed(let description):
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            messageLabel.stringValue = "Couldn’t load folder"
            messageLabel.toolTip = description
            retryButton.isHidden = false
        case .loaded:
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            messageLabel.stringValue = ""
            retryButton.isHidden = true
        }
    }

    @objc private func retryClicked() { onRetry?() }
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

    /// The synthetic ".." row: secondary-colored, no type dot, no badge.
    /// The parent folder's name rides along further dimmed so "up" has a
    /// visible destination; the full path stays in the tooltip.
    func configureAsParentDirectory(parentPath: String, dark: Bool) {
        let parentName = (parentPath as NSString).lastPathComponent
        let font = nameLabel.font ?? .systemFont(ofSize: 13)
        let secondary = ShellPalette.secondaryText(dark: dark)
        let text = NSMutableAttributedString(
            string: "..",
            attributes: [.font: font, .foregroundColor: secondary])
        if !parentName.isEmpty {
            text.append(NSAttributedString(
                string: "  \(parentName)",
                attributes: [
                    .font: font,
                    .foregroundColor: secondary.withAlphaComponent(0.65),
                ]))
        }
        nameLabel.attributedStringValue = text
        dotLabel.stringValue = ""
        gitBadgeLabel.stringValue = ""
        toolTip = "Go to parent folder: \(parentPath)"
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Parent folder \(parentName)")
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

    var displayedName: String { nameLabel.stringValue }

    /// Deterministic accessibility/test seam for committing the same text an
    /// inline editor would submit through its field-editor callback.
    func commitEditingName(_ name: String) {
        guard nameLabel.isEditable else { return }
        nameLabel.stringValue = name
        endEditing(commit: true)
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
