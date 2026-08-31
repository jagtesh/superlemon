// TreeSurfaceView — the native rendering of the surface-mode navbar
// (docs/design/surface-navbar-v1.md §8). A flat-row tree control: the model
// arrives as a buffer-line-ordered row list from the nvim runtime plugin;
// selection is driven externally (the navbar window's cursor line). Shares
// cell/row views with FileTreeSidebarView for pixel parity.
//
// PINNED CONTRACT STUB — the API below is the agreed seam between the
// ShellKit workstream (implementation + drag & drop + inline editing) and
// the EditorHostKit SurfaceHostRouter. Extend freely; do not rename or
// remove without updating the design doc.

import AppKit

/// One visible tree row. `id` is the absolute path (placeholders use a
/// synthetic id). Rows arrive in buffer-line order: row index == the nvim
/// buffer line (0-based) == the selection index.
public struct TreeSurfaceRow: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case file, dir, up, loading, failed
    }

    public var id: String
    public var label: String
    public var depth: Int
    public var kind: Kind
    public var expanded: Bool
    public var badge: TreeSurfaceBadge?
    /// Decoration dot color as "#RRGGBB", if any.
    public var dotColorHex: String?

    public init(
        id: String, label: String, depth: Int, kind: Kind,
        expanded: Bool = false, badge: TreeSurfaceBadge? = nil,
        dotColorHex: String? = nil
    ) {
        self.id = id
        self.label = label
        self.depth = depth
        self.kind = kind
        self.expanded = expanded
        self.badge = badge
        self.dotColorHex = dotColorHex
    }
}

public struct TreeSurfaceBadge: Equatable, Sendable {
    public var text: String
    public var colorHex: String?

    public init(text: String, colorHex: String? = nil) {
        self.text = text
        self.colorHex = colorHex
    }
}

/// Declarative context-menu item; shown for rows whose kind rawValue is in
/// `forKinds` ("root" targets the header/background area).
public struct TreeSurfaceMenuItem: Equatable, Sendable {
    public var id: String
    public var title: String
    public var forKinds: Set<String>

    public init(id: String, title: String, forKinds: Set<String>) {
        self.id = id
        self.title = title
        self.forKinds = forKinds
    }
}

public struct TreeSurfaceModel: Equatable, Sendable {
    /// Monotonic render sequence from the runtime plugin; stale models are
    /// dropped by the caller, the view just records it.
    public var seq: Int
    public var headerTitle: String
    public var menu: [TreeSurfaceMenuItem]
    public var rows: [TreeSurfaceRow]

    public init(
        seq: Int, headerTitle: String, menu: [TreeSurfaceMenuItem],
        rows: [TreeSurfaceRow]
    ) {
        self.seq = seq
        self.headerTitle = headerTitle
        self.menu = menu
        self.rows = rows
    }
}

// MARK: - Non-first-responder AppKit plumbing
//
// The navbar's AppKit control must never take keyboard focus (design §1:
// "AppKit first-responder focus never moves" — InputHostView stays the sole
// first responder). NSTableView normally calls `window?.makeFirstResponder`
// on click as part of its default selection handling; returning false here
// makes that call a harmless no-op while row selection/actions still fire
// (they don't depend on becoming first responder).

@MainActor
final class NonFirstResponderScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
}

@MainActor
final class NonFirstResponderTableView: NSTableView {
    override var acceptsFirstResponder: Bool { false }
}

/// Invisible resize handle at the trailing edge (§7 width drag).
@MainActor
private final class WidthDragStripView: NSView {
    var onDrag: ((CGFloat) -> Void)?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        onDrag?(max(0, point.x))
    }
}

/// Right-click target box for a declarative menu item (NSMenuItem's
/// representedObject wants a reference type).
@MainActor
private final class TreeSurfaceMenuAction: NSObject {
    let itemID: String
    let rowID: String
    init(itemID: String, rowID: String) {
        self.itemID = itemID
        self.rowID = rowID
    }
}

/// Native navbar overlay for the surface-mode vim window.
@MainActor
public final class TreeSurfaceView: NSView {

    public static let rowHeight: CGFloat = FileTreeSidebarView.rowHeight
    static let indentPerLevel: CGFloat = 17

    /// Synthetic id for the in-progress "new file/folder" row inserted by
    /// `beginCreate`. Never appears in a real model — filtered back out
    /// before comparing against incoming render payloads.
    private static let provisionalRowID = "\u{0}tree-surface-provisional"

    // MARK: Outbound callbacks (wired by SurfaceHostRouter / WorkspaceChrome)

    /// Row activated: single click (`permanent == false`) or double click
    /// (`permanent == true`) on a file row.
    public var onOpen: ((_ id: String, _ permanent: Bool) -> Void)?
    /// Disclosure chevron clicked, or a directory row double-clicked.
    public var onToggle: ((_ id: String) -> Void)?
    /// Context-menu selection.
    public var onMenu: ((_ itemID: String, _ rowID: String) -> Void)?
    /// Any row click, before open/toggle: lets the host sync the vim cursor
    /// (`nvim_win_set_cursor`) to the clicked buffer line (0-based).
    public var onRowClick: ((_ row: Int) -> Void)?
    /// Inline rename commit; returns an error message to keep the field
    /// open, or nil on success.
    public var onRenameCommit: ((_ id: String, _ name: String) async -> String?)?
    /// Inline create commit (provisional row under `dir`); same semantics.
    public var onCreateCommit:
        ((_ dir: String, _ kind: TreeSurfaceRow.Kind, _ name: String) async -> String?)?
    /// Right-edge resize handle drag; pixel width in view coordinates.
    public var onWidthDrag: ((CGFloat) -> Void)?

    // MARK: Drag & drop (mirrors FileTreeSidebarView's seams exactly, so the
    // embedder wires both controls identically — see WorkspaceChrome.swift's
    // sidebar wiring for the reference shape of each closure).

    /// External drop: local file URLs land in a workspace directory. The
    /// embedder runs the transfer (local copy or RPC upload). Unset
    /// disables drops. `directoryPath` is `""` for a drop on the root/empty
    /// area — see the root-id convention documented on `beginCreate` and
    /// `menuNeedsUpdate`.
    public var onDropFiles: ((_ urls: [URL], _ directoryPath: String) -> Void)?
    /// Internal drag between rows: a MOVE within the workspace.
    public var onMoveItems: ((_ sourcePaths: [String], _ directoryPath: String) -> Void)?
    /// Pasteboard writer for dragging a row OUT of the tree: a plain file
    /// URL when the workspace is this machine's filesystem, or an
    /// NSFilePromiseProvider for a remote workspace. Unset disables
    /// dragging out.
    public var dragWriterProvider: ((_ path: String, _ isDirectory: Bool) -> NSPasteboardWriting?)?
    /// Cancel button in the transfer band.
    public var onCancelTransfers: (() -> Void)? {
        get { transferBand.onCancel }
        set { transferBand.onCancel = newValue }
    }

    /// Paths captured at drag start; internal drops consume these instead of
    /// round-tripping through the pasteboard. Mirrors
    /// `FileTreeSidebarView.draggedNodePaths`.
    var draggedRowPaths: [String] = []
    private let promiseReceiveQueue = OperationQueue()

    // MARK: Inbound state

    public private(set) var model: TreeSurfaceModel?
    public private(set) var selectedRow: Int?

    /// The rendered rows, INCLUDING a provisional create row when one is
    /// active. Row index == table row index == (absent a provisional row)
    /// the model's row order, i.e. the nvim buffer line.
    private(set) var displayedRows: [TreeSurfaceRow] = []
    private var provisionalCreateDirectory: String?
    private var isDark = false
    private var isActive = false

    let tableView = NonFirstResponderTableView()
    private let scrollView = NonFirstResponderScrollView()
    private let headerLabel = NSTextField(labelWithString: "")
    private let transferBand = FileTransferProgressView()
    private var transferBandHeight: NSLayoutConstraint!
    private let widthDragStrip = WidthDragStripView()
    private let rowContextMenu = NSMenu()
    private let rootContextMenu = NSMenu()

    /// Test seam: the header title shown above the tree.
    var displayedHeaderTitle: String { headerLabel.stringValue }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("TreeSurfaceView does not support NSCoding")
    }

    private func setUp() {
        wantsLayer = true

        let column = NSTableColumn(identifier: .init("row"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.doubleAction = #selector(rowDoubleClicked)

        rowContextMenu.delegate = self
        rootContextMenu.delegate = self
        tableView.menu = rowContextMenu

        var draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL]
        draggedTypes += NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
        tableView.registerForDraggedTypes(draggedTypes)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        headerLabel.font = .boldSystemFont(ofSize: 13)
        headerLabel.lineBreakMode = .byTruncatingMiddle
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.setAccessibilityIdentifier("surface.header")
        headerLabel.menu = rootContextMenu
        addSubview(headerLabel)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        transferBand.translatesAutoresizingMaskIntoConstraints = false
        transferBand.isHidden = true
        addSubview(transferBand)
        transferBandHeight = transferBand.heightAnchor.constraint(equalToConstant: 0)

        widthDragStrip.translatesAutoresizingMaskIntoConstraints = false
        widthDragStrip.onDrag = { [weak self] width in self?.onWidthDrag?(width) }
        addSubview(widthDragStrip)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 5),
            scrollView.bottomAnchor.constraint(equalTo: transferBand.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            transferBand.leadingAnchor.constraint(equalTo: leadingAnchor),
            transferBand.trailingAnchor.constraint(equalTo: trailingAnchor),
            transferBand.bottomAnchor.constraint(equalTo: bottomAnchor),
            transferBandHeight,
            widthDragStrip.topAnchor.constraint(equalTo: topAnchor),
            widthDragStrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthDragStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthDragStrip.widthAnchor.constraint(equalToConstant: 6),
        ])

        applyAppearance(dark: false)
    }

    public override var acceptsFirstResponder: Bool { false }

    /// Shows/updates the bottom transfer band; nil collapses it. Mirrors
    /// `FileTreeSidebarView.renderTransferProgress` exactly.
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
        tableView.backgroundColor = .clear
        headerLabel.textColor = ShellPalette.primaryText(dark: dark)
        transferBand.applyAppearance(dark: dark)
        tableView.reloadData()
    }

    // MARK: Render / diff

    /// Apply a full model; diffed by row id to preserve scroll position and
    /// avoid flicker. Full reload only when the diff is degenerate (more
    /// than half the rows changed identity).
    public func render(_ model: TreeSurfaceModel) {
        self.model = model
        headerLabel.stringValue = model.headerTitle
        headerLabel.toolTip = model.headerTitle

        // A create-in-flight provisional row is host-local UI state that
        // never appears in a real render payload; keep it pinned at its
        // current position across this render instead of losing the
        // in-progress edit out from under the user.
        var newRows = model.rows
        if let provisionalIndex = displayedRows.firstIndex(where: { $0.id == Self.provisionalRowID }) {
            newRows.insert(displayedRows[provisionalIndex], at: min(provisionalIndex, newRows.count))
        }
        applyDiff(to: newRows)
    }

    private func applyDiff(to newRows: [TreeSurfaceRow]) {
        let oldRows = displayedRows
        let oldIDs = oldRows.map(\.id)
        let newIDs = newRows.map(\.id)
        let diff = newIDs.difference(from: oldIDs)
        let churn = diff.insertions.count + diff.removals.count
        let maxCount = max(oldIDs.count, newIDs.count, 1)

        guard Double(churn) / Double(maxCount) <= 0.5 else {
            // Degenerate diff: cheaper and safer to reload wholesale.
            let scrollOrigin = scrollView.contentView.bounds.origin
            displayedRows = newRows
            tableView.reloadData()
            scrollView.contentView.scroll(to: scrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }

        displayedRows = newRows
        tableView.beginUpdates()
        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                tableView.removeRows(at: IndexSet(integer: offset), withAnimation: [])
            case .insert(let offset, _, _):
                tableView.insertRows(at: IndexSet(integer: offset), withAnimation: [])
            }
        }
        tableView.endUpdates()

        // Rows whose id survived the diff but whose content changed
        // (expanded flag, badge, label, …) still need a fresh cell.
        let oldByID = Dictionary(oldRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var reloadRows = IndexSet()
        for (index, row) in newRows.enumerated() where oldByID[row.id].map({ $0 != row }) ?? false {
            reloadRows.insert(index)
        }
        if !reloadRows.isEmpty {
            tableView.reloadData(forRowIndexes: reloadRows, columnIndexes: IndexSet(integer: 0))
        }
    }

    // MARK: Selection / active state

    /// Externally driven selection (the navbar window's cursor line,
    /// 0-based). Scrolls to reveal only when the row actually changed.
    public func setSelectedRow(_ row: Int?) {
        let changed = row != selectedRow
        selectedRow = row
        guard let row, row >= 0, row < displayedRows.count else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if changed {
            tableView.scrollRowToVisible(row)
        }
    }

    /// Whether the navbar vim window is the current (cursor) window:
    /// emphasized vs. secondary selection styling.
    public func setActive(_ active: Bool) {
        isActive = active
        tableView.enumerateAvailableRowViews { rowView, _ in
            (rowView as? FileTreeRowView)?.isRowEmphasized = active
        }
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        performRowAction(row: tableView.clickedRow, isDoubleClick: false)
    }

    @objc private func rowDoubleClicked() {
        performRowAction(row: tableView.clickedRow, isDoubleClick: true)
    }

    /// Internal for tests (mirrors `FileTreeSidebarView.performRowAction`).
    func performRowAction(row: Int, isDoubleClick: Bool) {
        guard row >= 0, row < displayedRows.count else { return }
        let treeRow = displayedRows[row]
        if !isDoubleClick {
            onRowClick?(row)
        }
        switch treeRow.kind {
        case .dir:
            if isDoubleClick { onToggle?(treeRow.id) }
        case .file:
            if isDoubleClick {
                onOpen?(treeRow.id, true)
            } else {
                onOpen?(treeRow.id, false)
            }
        case .up, .loading, .failed:
            guard !isDoubleClick else { return }
            // A failed row's click retries the load; the ".." row and a
            // loading placeholder just forward "activate" the same way —
            // Lua already knows each row's kind and decides what it means.
            onOpen?(treeRow.id, false)
        }
    }

    // MARK: Inline rename / create

    /// Begin inline rename of the given row (context menu drives this).
    public func beginRename(rowID: String) {
        guard let index = displayedRows.firstIndex(where: { $0.id == rowID }) else { return }
        startEditingCell(atRow: index) { [weak self] name in
            self?.handleRenameCommit(id: rowID, name: name)
        }
    }

    /// Show a provisional inline-named row for a new file/folder in `dir`.
    ///
    /// Root-id convention: `dirID` is looked up among the CURRENTLY
    /// DISPLAYED directory rows. Root itself has no row in the flat list
    /// (it is the implicit parent of row 0), so a `dirID` that matches no
    /// displayed dir row is treated as the root and the provisional row is
    /// inserted at the top — this mirrors the "" root id the context menu
    /// uses for header/empty-area clicks (see `menuNeedsUpdate`).
    public func beginCreate(dirID: String, kind: TreeSurfaceRow.Kind) {
        removeProvisionalRow()
        let insertIndex: Int
        let depth: Int
        if let dirIndex = displayedRows.firstIndex(where: { $0.id == dirID && $0.kind == .dir }) {
            insertIndex = dirIndex + 1
            depth = displayedRows[dirIndex].depth + 1
        } else {
            insertIndex = 0
            depth = 0
        }
        let row = TreeSurfaceRow(id: Self.provisionalRowID, label: "", depth: depth, kind: kind)
        displayedRows.insert(row, at: insertIndex)
        tableView.insertRows(at: IndexSet(integer: insertIndex), withAnimation: [])
        provisionalCreateDirectory = dirID
        startEditingCell(atRow: insertIndex) { [weak self] name in
            self?.handleCreateCommit(dir: dirID, kind: kind, name: name)
        }
    }

    private func startEditingCell(atRow row: Int, onCommit: @escaping (String) -> Void) {
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? FileTreeCellView
        else { return }
        cell.beginEditing(onCommit: onCommit)
    }

    private func handleRenameCommit(id: String, name: String) {
        guard let index = displayedRows.firstIndex(where: { $0.id == id }) else { return }
        // Empty (or unchanged, e.g. Escape reverting the field) cancels
        // silently — no RPC round trip for a no-op.
        guard !name.isEmpty, name != displayedRows[index].label else { return }
        guard let onRenameCommit else { return }
        Task { [weak self] in
            if let error = await onRenameCommit(id, name) {
                self?.showRenameError(error, forRowID: id)
            }
            // nil → success: the authoritative row text arrives on the next
            // render; nothing further to do here.
        }
    }

    private func showRenameError(_ message: String, forRowID id: String) {
        guard let index = displayedRows.firstIndex(where: { $0.id == id }) else { return }
        NSSound.beep()
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: true)
            as? FileTreeCellView
        else { return }
        cell.toolTip = message
        cell.beginEditing { [weak self] name in
            self?.handleRenameCommit(id: id, name: name)
        }
    }

    private func handleCreateCommit(dir: String, kind: TreeSurfaceRow.Kind, name: String) {
        guard !name.isEmpty else {
            removeProvisionalRow()
            return
        }
        guard let onCreateCommit else { return }
        Task { [weak self] in
            if let error = await onCreateCommit(dir, kind, name) {
                self?.showCreateError(error)
            } else {
                self?.removeProvisionalRow()
            }
        }
    }

    private func showCreateError(_ message: String) {
        guard let index = displayedRows.firstIndex(where: { $0.id == Self.provisionalRowID }),
            let dir = provisionalCreateDirectory
        else { return }
        let kind = displayedRows[index].kind
        NSSound.beep()
        guard let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: true)
            as? FileTreeCellView
        else { return }
        cell.toolTip = message
        cell.beginEditing { [weak self] name in
            self?.handleCreateCommit(dir: dir, kind: kind, name: name)
        }
    }

    /// Escape/empty cancels; removes the provisional row without touching
    /// anything else in the list.
    private func removeProvisionalRow() {
        guard let index = displayedRows.firstIndex(where: { $0.id == Self.provisionalRowID })
        else { return }
        displayedRows.remove(at: index)
        tableView.removeRows(at: IndexSet(integer: index), withAnimation: [])
        provisionalCreateDirectory = nil
    }

    // MARK: Drag & drop

    /// The absolute path of the directory a drop targets: a directory row
    /// receives directly, a file forwards to its parent (paths are ids, so
    /// this is a pure string operation — no tree walk needed), and
    /// everything else (including "no row", i.e. the empty area or the
    /// header band) resolves to `""` — the same root convention as
    /// `beginCreate`/`menuNeedsUpdate`.
    private func dropTargetDirectoryID(forRow row: Int) -> String {
        guard row >= 0, row < displayedRows.count else { return "" }
        let treeRow = displayedRows[row]
        switch treeRow.kind {
        case .dir: return treeRow.id
        case .file: return (treeRow.id as NSString).deletingLastPathComponent
        case .up, .loading, .failed: return ""
        }
    }

    private func isInternalDrag(_ info: NSDraggingInfo) -> Bool {
        (info.draggingSource as? NSTableView) === tableView
    }

    /// Paths that actually change parent, excluding drops into a dragged
    /// item's own subtree. Mirrors `FileTreeSidebarView.movablePaths`.
    func movablePaths(into directory: String) -> [String] {
        guard !draggedRowPaths.contains(where: {
            directory == $0 || directory.hasPrefix($0 + "/")
        }) else { return [] }
        return draggedRowPaths.filter {
            ($0 as NSString).deletingLastPathComponent != directory
        }
    }

    /// Promise-based drags materialize in a private staging directory first,
    /// then enter the normal dropped-URL flow. Mirrors
    /// `FileTreeSidebarView.receivePromisedFiles` (including reusing its
    /// staging-directory sweep) so both controls share one cleanup policy.
    func receivePromisedFiles(_ receivers: [NSFilePromiseReceiver], into directory: String) {
        FileTreeSidebarView.sweepStalePromisedStagingDirectories()
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("superlemon-promised-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
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
            guard !urls.isEmpty else {
                try? FileManager.default.removeItem(at: staging)
                return
            }
            Task { @MainActor [weak self] in
                self?.onDropFiles?(urls, directory)
            }
        }
    }
}

// MARK: - Data source / delegate

extension TreeSurfaceView: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }

    public func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard row >= 0, row < displayedRows.count else { return nil }
        let treeRow = displayedRows[row]
        switch treeRow.kind {
        case .loading, .failed:
            let identifier = NSUserInterfaceItemIdentifier("TreeSurfacePlaceholderCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? FileTreePlaceholderCellView ?? FileTreePlaceholderCellView(identifier: identifier)
            cell.configure(kind: treeRow.kind, message: treeRow.label) { [weak self] in
                self?.onOpen?(treeRow.id, false)
            }
            return cell
        case .up:
            let identifier = NSUserInterfaceItemIdentifier("TreeSurfaceUpCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? FileTreeCellView ?? FileTreeCellView(identifier: identifier)
            cell.onChevronTap = nil
            cell.configureAsParentDirectory(parentPath: treeRow.id, dark: isDark)
            cell.configureIndent(depth: 0, showsChevron: false, expanded: false)
            return cell
        case .file, .dir:
            let identifier = NSUserInterfaceItemIdentifier("TreeSurfaceCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? FileTreeCellView ?? FileTreeCellView(identifier: identifier)
            cell.configure(row: treeRow, dark: isDark)
            cell.onChevronTap = treeRow.kind == .dir
                ? { [weak self] in self?.onToggle?(treeRow.id) }
                : nil
            return cell
        }
    }

    public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileTreeRowView(dark: isDark, emphasized: isActive)
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Self.rowHeight
    }

    // MARK: Drag source

    public func tableView(
        _ tableView: NSTableView, pasteboardWriterForRow row: Int
    ) -> NSPasteboardWriting? {
        guard row >= 0, row < displayedRows.count else { return nil }
        let treeRow = displayedRows[row]
        guard treeRow.kind == .file || treeRow.kind == .dir else { return nil }
        return dragWriterProvider?(treeRow.id, treeRow.kind == .dir)
    }

    public func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet
    ) {
        draggedRowPaths = rowIndexes.compactMap {
            $0 < displayedRows.count ? displayedRows[$0].id : nil
        }
    }

    public func tableView(
        _ tableView: NSTableView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        draggedRowPaths = []
    }

    // MARK: Drop target

    public func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        let probeRow = dropOperation == .on ? row : row - 1
        let directory = dropTargetDirectoryID(forRow: probeRow)
        if let dirRow = displayedRows.indices.first(where: {
            displayedRows[$0].id == directory && displayedRows[$0].kind == .dir
        }) {
            tableView.setDropRow(dirRow, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        if isInternalDrag(info) {
            guard onMoveItems != nil, !movablePaths(into: directory).isEmpty else { return [] }
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

    public func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        let probeRow = dropOperation == .on ? row : row - 1
        let directory = dropTargetDirectoryID(forRow: probeRow)
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
}

// MARK: - Context menu

extension TreeSurfaceView: NSMenuDelegate {

    /// Built from `model.menu`, filtered by the clicked row's kind rawValue.
    /// `rowContextMenu` (attached to the table) resolves its target from
    /// `tableView.clickedRow` — a real row's kind, or "root" when the click
    /// landed on empty table area. `rootContextMenu` (attached to the header
    /// label) is always "root". Root-area selections carry `rowID == ""`;
    /// the host/Lua resolves that to the tree's actual root path — the same
    /// decision `beginCreate` and the drop-target resolver make.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }

        let targetKind: String
        let rowID: String
        if menu === rowContextMenu, tableView.clickedRow >= 0,
            tableView.clickedRow < displayedRows.count
        {
            let row = displayedRows[tableView.clickedRow]
            targetKind = row.kind.rawValue
            rowID = row.id
        } else {
            targetKind = "root"
            rowID = ""
        }

        for item in model.menu where item.forKinds.contains(targetKind) {
            let menuItem = NSMenuItem(
                title: item.title, action: #selector(menuItemSelected(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = TreeSurfaceMenuAction(itemID: item.id, rowID: rowID)
            menu.addItem(menuItem)
        }
    }

    @objc private func menuItemSelected(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? TreeSurfaceMenuAction else { return }
        onMenu?(action.itemID, action.rowID)
    }
}
