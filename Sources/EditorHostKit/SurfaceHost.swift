// SurfaceHostRouter — the GUI half of the surface-mode navbar
// (docs/design/surface-navbar-v1.md §7). Routes the ("surface", …) and
// ("host", …) components of the `superlemon.ui` plane, maps the navbar
// window to its multigrid grid, suppresses that grid's text rendering,
// mounts and positions the native TreeSurfaceView overlay, derives
// selection/active state from each flush (win_viewport.curline / cursor
// grid), and dispatches control events back through ui._dispatch.
//
// PINNED CONTRACT STUB — the seams below are wired by EditorHostNSView /
// WorkspaceChrome / NvimController in the main session. Extend freely; do
// not rename or remove without updating the design doc.

import AppKit
import Foundation
import GridKit
import NvimKit
import ShellKit
import os

@MainActor
final class SurfaceHostRouter {

    private weak var controller: NvimController?
    private let logger = Logger(subsystem: "com.superlemon.app", category: "surface")

    /// The native overlay control for the (single, v1) tree surface.
    private(set) var treeView: TreeSurfaceView?

    /// True while a surface is open (an `open` arrived without a matching
    /// `close`), even if its grid has not appeared in a flush yet.
    private(set) var isActive = false

    // MARK: State (v1: exactly one surface)

    private var surfaceID: String?
    private var win: Int?
    private var buf: Int?
    private var eventCb: Int?
    /// Monotonic render sequence last applied; renders with `seq <=` this are
    /// dropped as stale.
    private var latestSeq = -1
    /// A render that arrived before `open` created the view; applied once it
    /// does. Keyed by the surface id it targeted so a stale surface's render
    /// is never applied to a newer one.
    private var pendingModel: (surfaceID: String, model: TreeSurfaceModel)?
    /// The grid last resolved for `win` (winid → grid, §7). Used to notice
    /// the grid disappearing (window closed) without an explicit `close`.
    private var knownGridID: Int?
    private var lastSelectedRow: Int?
    private var lastActive: Bool?

    // MARK: Wiring seams (set once by EditorHostNSView / WorkspaceChrome)

    /// Add / remove the overlay view in the input-host view hierarchy.
    var mountOverlay: ((NSView) -> Void)?
    var unmountOverlay: ((NSView) -> Void)?
    /// Frame for a grid id, in the overlay superview's coordinate space
    /// (nil while the grid is unknown → overlay hidden).
    var overlayFrame: ((_ gridID: Int) -> NSRect?)?
    /// Forwarded to GridSurfaceView.setOverlaidWindowHandles.
    var setOverlaidWindowHandles: ((Set<Int>) -> Void)?
    /// Transient error reporting (host trash failures etc.).
    var showToast: ((String) -> Void)?
    /// `nvim_win_set_cursor(win, {line0 + 1, 0})` — row click → vim
    /// selection sync. The router passes the 0-based row; the wirer converts
    /// to nvim's 1-based line.
    var setWindowCursor: ((_ win: Int, _ line0: Int) -> Void)?
    /// `nvim_win_set_width(win, cols)` — right-edge drag resize.
    var setWindowWidth: ((_ win: Int, _ cols: Int) -> Void)?
    /// Current cell width in points, for converting `onWidthDrag`'s pixel
    /// width into columns.
    var cellWidth: (() -> CGFloat)?
    /// Called with each freshly created tree view before it is mounted —
    /// WorkspaceChrome wires the drag & drop/transfer seams here (they need
    /// the file-transfer coordinator, which the router deliberately doesn't
    /// know about).
    var configureTreeView: ((TreeSurfaceView) -> Void)?

    /// Minimum navbar width per §10 item 11: ~180 pt worth of columns.
    private static let minimumWidthPoints: CGFloat = 180

    init(controller: NvimController?) {
        self.controller = controller
    }

    /// Entry point from WorkspaceChrome's `superlemon.ui` routing. Returns
    /// true when the (component, method) belongs to this router.
    func handle(component: String, method: String, namespace: String, args: Value) -> Bool {
        switch component {
        case "surface":
            switch method {
            case "open": handleOpen(args)
            case "render": handleRender(args)
            case "close": handleClose(args)
            default: logUnknown(component, method)
            }
            return true
        case "host":
            switch method {
            case "trash": handleTrash(args)
            case "reveal": handleReveal(args)
            default: logUnknown(component, method)
            }
            return true
        default:
            return false
        }
    }

    /// Called by NvimController after every `surface.present(flush)`:
    /// resolve winid → grid, keep suppression + overlay frame current, and
    /// derive selection (viewport.curline) and active state (cursor grid).
    func sync(flush: FlushResult) {
        guard isActive, let win else { return }

        // The grid this window owned has vanished without an explicit
        // `close` notification (e.g. the notification raced or was
        // dropped) — infer the close rather than leaving a stuck overlay.
        if let knownGridID, flush.grids[knownGridID] == nil {
            teardown()
            return
        }

        setOverlaidWindowHandles?([win])

        guard let gridID = flush.grids.first(where: { $0.value.windowHandle == win })?.key,
            let grid = flush.grids[gridID]
        else {
            // Racing the first flush: tolerate, stay hidden until it appears.
            knownGridID = nil
            treeView?.isHidden = true
            return
        }
        knownGridID = gridID

        if var frame = overlayFrame?(gridID) {
            // Cover nvim's window-separator glyph column too: the tree view
            // draws a continuous native hairline at its trailing edge in
            // place of the `|` cell column.
            frame.size.width += cellWidth?() ?? 0
            treeView?.frame = frame
            treeView?.isHidden = false
        } else {
            treeView?.isHidden = true
        }

        if let curline = grid.viewport?.curline, curline != lastSelectedRow {
            lastSelectedRow = curline
            treeView?.setSelectedRow(curline)
        }
        if grid.hasCursor != lastActive {
            lastActive = grid.hasCursor
            treeView?.setActive(grid.hasCursor)
        }
    }

    func applyAppearance(dark: Bool) {
        treeView?.applyAppearance(dark: dark)
    }

    // MARK: - surface.open / render / close

    private func handleOpen(_ args: Value) {
        guard let decoded = Self.decodeOpenPayload(args) else {
            return logMalformed("surface", "open")
        }
        // A second open (e.g. a stale surface never got its close) replaces
        // whatever came before it.
        if treeView != nil { teardown() }

        surfaceID = decoded.surfaceID
        win = decoded.win
        buf = decoded.buf
        eventCb = decoded.eventCb
        isActive = true
        latestSeq = -1
        knownGridID = nil
        lastSelectedRow = nil
        lastActive = nil

        let view = TreeSurfaceView(frame: .zero)
        wireCallbacks(view)
        configureTreeView?(view)
        treeView = view
        mountOverlay?(view)

        if let pending = pendingModel, pending.surfaceID == decoded.surfaceID {
            applyModel(pending.model)
        }
        pendingModel = nil
    }

    private func handleRender(_ args: Value) {
        guard let renderSurfaceID = args["surface_id"]?.stringValue,
            let decoded = Self.decodeRenderModel(args)
        else {
            return logMalformed("surface", "render")
        }
        guard treeView != nil, surfaceID == renderSurfaceID else {
            // Not mounted yet: stash for `open` to apply. A render for a
            // foreign/stale surface id (already closed, or not ours) is
            // otherwise dropped.
            if treeView == nil {
                pendingModel = (renderSurfaceID, decoded.model)
            }
            return
        }
        guard decoded.seq > latestSeq else { return }
        applyModel(decoded.model)
    }

    private func handleClose(_ args: Value) {
        if let closedID = Self.decodeCloseSurfaceID(args), let surfaceID, closedID != surfaceID {
            return  // stale close for a surface that is no longer current
        }
        teardown()
    }

    private func applyModel(_ model: TreeSurfaceModel) {
        latestSeq = model.seq
        treeView?.render(model)
    }

    private func teardown() {
        if let treeView { unmountOverlay?(treeView) }
        treeView = nil
        isActive = false
        surfaceID = nil
        win = nil
        buf = nil
        eventCb = nil
        knownGridID = nil
        latestSeq = -1
        lastSelectedRow = nil
        lastActive = nil
        pendingModel = nil
        setOverlaidWindowHandles?([])
    }

    // MARK: - host.trash / reveal

    private func handleTrash(_ args: Value) {
        guard let path = Self.decodeHostPath(args) else {
            return logMalformed("host", "trash")
        }
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            showToast?("Couldn't move \(url.lastPathComponent) to Trash")
        }
    }

    private func handleReveal(_ args: Value) {
        guard let path = Self.decodeHostPath(args) else {
            return logMalformed("host", "reveal")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - TreeSurfaceView callback wiring (§6 GUI → nvim events)

    private func wireCallbacks(_ view: TreeSurfaceView) {
        view.onRowClick = { [weak self] row in
            guard let self, let win = self.win else { return }
            self.setWindowCursor?(win, row)
        }
        view.onOpen = { [weak self] id, permanent in
            self?.dispatchDetached([
                (.string("event"), .string("open")),
                (.string("id"), .string(id)),
                (.string("permanent"), .bool(permanent)),
            ])
        }
        view.onToggle = { [weak self] id in
            self?.dispatchDetached([
                (.string("event"), .string("toggle")),
                (.string("id"), .string(id)),
            ])
        }
        view.onMenu = { [weak self] itemID, rowID in
            guard let self else { return }
            switch itemID {
            case "rename":
                self.treeView?.beginRename(rowID: rowID)
            case "new_file", "new_folder":
                let kind: TreeSurfaceRow.Kind = itemID == "new_file" ? .file : .dir
                self.treeView?.beginCreate(
                    dirID: self.directoryID(forMenuRow: rowID), kind: kind)
            default:
                self.dispatchDetached([
                    (.string("event"), .string("menu")),
                    (.string("id"), .string(rowID)),
                    (.string("item"), .string(itemID)),
                ])
            }
        }
        view.onRenameCommit = { [weak self] id, name in
            guard let self else { return "surface closed" }
            return await self.performRename(id: id, name: name)
        }
        view.onCreateCommit = { [weak self] dir, kind, name in
            guard let self else { return "surface closed" }
            return await self.performCreate(dir: dir, kind: kind, name: name)
        }
        view.onWidthDrag = { [weak self] pixelWidth in
            self?.handleWidthDrag(pixelWidth)
        }
    }

    private func dispatchDetached(_ payload: [(Value, Value)]) {
        guard let eventCb else { return }
        controller?.dispatchUICallbackDetached(eventCb, payload: payload)
    }

    private func performRename(id: String, name: String) async -> String? {
        guard let controller, let eventCb else { return "surface closed" }
        let reply = await controller.dispatchUICallback(
            eventCb,
            payload: [
                (.string("event"), .string("rename")),
                (.string("id"), .string(id)),
                (.string("name"), .string(name)),
            ])
        return Self.decodeCallbackError(reply)
    }

    private func performCreate(
        dir: String, kind: TreeSurfaceRow.Kind, name: String
    ) async -> String? {
        guard let controller, let eventCb else { return "surface closed" }
        let kindString = kind == .file ? "file" : "folder"
        let reply = await controller.dispatchUICallback(
            eventCb,
            payload: [
                (.string("event"), .string("create")),
                (.string("dir"), .string(dir)),
                (.string("kind"), .string(kindString)),
                (.string("name"), .string(name)),
            ])
        return Self.decodeCallbackError(reply)
    }

    /// Resolve the `new_file`/`new_folder` menu target: the row itself when
    /// it's a directory/`..`; its parent path for a file; the id verbatim
    /// when it doesn't match a known row (root/background menu — already
    /// the target directory).
    private func directoryID(forMenuRow rowID: String) -> String {
        guard let row = treeView?.model?.rows.first(where: { $0.id == rowID }) else {
            return rowID
        }
        switch row.kind {
        case .dir, .up:
            return row.id
        case .file, .loading, .failed:
            return (row.id as NSString).deletingLastPathComponent
        }
    }

    private func handleWidthDrag(_ pixelWidth: CGFloat) {
        guard let win, let cellWidth = cellWidth?(), cellWidth > 0 else { return }
        let minimumCols = Int(ceil(Self.minimumWidthPoints / cellWidth))
        // The overlay is one cell wider than the vim window (it covers the
        // separator column); subtract it before converting to columns.
        let cols = max(minimumCols, Int(((pixelWidth - cellWidth) / cellWidth).rounded()))
        setWindowWidth?(win, cols)
    }

    // MARK: - Decoding (pure, static — unit-testable)

    static func decodeOpenPayload(
        _ args: Value
    ) -> (surfaceID: String, win: Int, buf: Int, eventCb: Int)? {
        guard let surfaceID = args["surface_id"]?.stringValue,
            let win = args["win"]?.intValue,
            let buf = args["buf"]?.intValue,
            let eventCb = args["event_cb"]?.intValue
        else { return nil }
        return (surfaceID, win, buf, eventCb)
    }

    static func decodeCloseSurfaceID(_ args: Value) -> String? {
        args["surface_id"]?.stringValue
    }

    static func decodeHostPath(_ args: Value) -> String? {
        args["path"]?.stringValue
    }

    /// `superlemon.ui` `("surface", "render", …)` args → the §6 render
    /// payload, mapped onto `TreeSurfaceModel`. `nil` when `seq`/`rows` (the
    /// load-bearing fields) are missing or malformed — including ANY
    /// malformed row: `rows[i] == buffer line i` is the projection
    /// invariant, so silently skipping a row would shift every index after
    /// it and desync selection from the vim cursor. Bad menu items are
    /// merely cosmetic and are skipped.
    static func decodeRenderModel(_ args: Value) -> (seq: Int, model: TreeSurfaceModel)? {
        guard let seq = args["seq"]?.intValue,
            let rowValues = args["rows"]?.arrayValue
        else { return nil }
        let headerTitle = args["header"]?["title"]?.stringValue ?? ""
        let menu = (args["menu"]?.arrayValue ?? []).compactMap(decodeMenuItem)
        let rows = rowValues.compactMap(decodeRow)
        guard rows.count == rowValues.count else { return nil }
        let model = TreeSurfaceModel(
            seq: seq, headerTitle: headerTitle, menu: menu, rows: rows)
        return (seq, model)
    }

    static func decodeMenuItem(_ value: Value) -> TreeSurfaceMenuItem? {
        guard let id = value["id"]?.stringValue,
            let title = value["title"]?.stringValue
        else { return nil }
        let forKinds = Set((value["for_kinds"]?.arrayValue ?? []).compactMap(\.stringValue))
        return TreeSurfaceMenuItem(id: id, title: title, forKinds: forKinds)
    }

    static func decodeRow(_ value: Value) -> TreeSurfaceRow? {
        guard let id = value["id"]?.stringValue,
            let label = value["label"]?.stringValue,
            let depth = value["depth"]?.intValue,
            let kindRaw = value["kind"]?.stringValue,
            let kind = TreeSurfaceRow.Kind(rawValue: kindRaw)
        else { return nil }
        let expanded = value["expanded"]?.boolValue ?? false
        let badge = value["badge"].flatMap { badgeValue -> TreeSurfaceBadge? in
            guard let text = badgeValue["text"]?.stringValue else { return nil }
            return TreeSurfaceBadge(text: text, colorHex: badgeValue["color"]?.stringValue)
        }
        let dotColorHex = value["dot"]?.stringValue
        return TreeSurfaceRow(
            id: id, label: label, depth: depth, kind: kind, expanded: expanded,
            badge: badge, dotColorHex: dotColorHex)
    }

    /// A blocking callback's reply → an error message, or nil on success
    /// (`{ok = true}`). A nil reply means the round trip itself failed
    /// (freed id, Lua error, no session) — surfaced as an error so the
    /// inline field stays open rather than silently appearing to succeed.
    static func decodeCallbackError(_ reply: Value?) -> String? {
        guard let reply else { return "no response" }
        return reply["error"]?.stringValue
    }

    // MARK: - Logging

    private func logMalformed(_ component: String, _ method: String) {
        logger.error(
            "superlemon.ui: malformed args for \(component, privacy: .public).\(method, privacy: .public)"
        )
    }

    private func logUnknown(_ component: String, _ method: String) {
        logger.error(
            "superlemon.ui: unknown \(component, privacy: .public).\(method, privacy: .public)")
    }
}
