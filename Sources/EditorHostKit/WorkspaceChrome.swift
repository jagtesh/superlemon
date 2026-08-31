// WorkspaceChrome — owns every native chrome component and its wiring:
// ChromeKit (cmdline palette, popupmenu, toasts, confirm alerts), ShellKit
// (sidebar, status bar, quick-open), and the superlemon.* RPC notifications.
// See Sources/ChromeKit/WIRING.md and Sources/ShellKit/WIRING.md.

import AppKit
import ChromeKit
import GridKit
import NvimKit
import ShellKit
import SurfaceKit
import UniformTypeIdentifiers

private struct WorkspaceFileMutationResult: Sendable {
    let errorDescription: String?
    let resultingPath: String?
    var succeeded: Bool { errorDescription == nil }
}

enum QuickOpenSelectionError: Error, Equatable, LocalizedError {
    case outsideWorkspace(String)
    case notAFile(String)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let path):
            return "The selected result is outside the current workspace: \(path)"
        case .notAFile(let path):
            return "The selected file no longer exists: \(path)"
        }
    }
}

/// Serializes sidebar mutations away from the main actor. Besides keeping
/// FileManager I/O off the UI thread, this prevents two rapid context-menu
/// actions from racing each other against the same path.
private actor WorkspaceFileMutationQueue {
    func perform(_ operation: FileOperation) -> WorkspaceFileMutationResult {
        do {
            let result = try FileOperations.perform(operation)
            return WorkspaceFileMutationResult(
                errorDescription: nil, resultingPath: result?.path)
        } catch {
            return WorkspaceFileMutationResult(
                errorDescription: error.localizedDescription, resultingPath: nil)
        }
    }
}

@MainActor
public final class WorkspaceChrome {
    let chromeState = ChromeState()
    let cmdlinePanel: CmdlinePanelController
    let popupMenu: PopupMenuPanelController
    public let toasts = MessageToastController()

    let statusBar = StatusBarView()
    let sidebar: FileTreeSidebarView
    let quickOpen = QuickOpenPanelController()
    let tabStrip = BufferTabStripView()
    private(set) var fileIndex: FileIndex
    /// Where the sidebar tree and quick-open index come from. `.local` reads
    /// this machine's filesystem; a session-backed access reads through the
    /// nvim RPC channel (remote transports). Local-only affordances —
    /// FSEvents watching, sidebar file operations, and pre-open stat
    /// validation — are gated on `fileAccess.isLocal`.
    private let fileAccess: WorkspaceFileAccess

    /// Native-chrome toggles, mirrored from nvim (`superlemon.chrome` —
    /// nvim is the source of truth). The app delegate resizes the layout.
    var onChromeModeChange: ((
        _ nativeTabs: Bool, _ nativeStatusbar: Bool,
        _ nativeMinimap: Bool, _ nativeScrollbars: Bool,
        _ nativeSidebar: Bool
    ) -> Void)?
    /// The default Neovim save mapping requests the native sheet for an
    /// unnamed buffer. AppDelegate supplies the document-panel presentation.
    public var onSaveAsRequested: (() -> Void)?
    public private(set) var nativeTabs = false
    public private(set) var nativeStatusbar = false
    public private(set) var nativeMinimap = true
    private(set) var nativeScrollbars = false
    public private(set) var nativeSidebar = true

    private weak var controller: NvimController?
    private weak var window: NSWindow?
    private weak var surface: GridSurfaceView?
    public private(set) var projectRoot: URL
    /// Invalidates quick-open work started against an earlier project root.
    private var fileIndexGeneration = 0
    private var quickOpenQueryGeneration: UInt64 = 0
    private var quickOpenQueryTask: Task<Void, Never>?
    private var workspaceRefreshTask: Task<Void, Never>?
    private let fileMutationQueue = WorkspaceFileMutationQueue()
    private let fileWatcher = WorkspaceFileWatcher()
    /// Drag-and-drop transfer batches between this machine and the
    /// workspace filesystem (WorkspaceFileTransfer.swift).
    let fileTransfers: WorkspaceFileTransferCoordinator
    /// Shared delegate for remote drag-out promises; NSFilePromiseProvider
    /// does not retain its delegate, so the chrome owns it.
    private var remoteDragPromiseDelegate: RemoteDragPromiseDelegate?
    private var confirmAlertShowing = false
    /// Identity of the last-presented popup menu: selection changes preserve
    /// it; anything else forces a re-anchor (see syncChrome).
    private struct PumIdentity: Equatable {
        let items: [PopupMenuItem]
        let grid: Int
        let row: Int
        let col: Int
    }
    private var lastPumIdentity: PumIdentity?
    /// Returns key focus to the editor (set by AppDelegate).
    var restoreFocus: (() -> Void)?

    /// The superlemon.ui component framework router (CONTRACT.md,
    /// DESIGN §15). Lazy so `self` is fully initialized when created.
    private(set) lazy var uiRouter = UIComponentRouter(
        chrome: self, controller: controller, projectRoot: projectRoot)

    /// Surface-mode navbar host (docs/design/surface-navbar-v1.md §7): owns
    /// the ("surface", …)/("host", …) components of the superlemon.ui plane.
    /// Its view-hierarchy seams are wired by EditorHostNSView.
    private(set) lazy var surfaceHost: SurfaceHostRouter = {
        let router = SurfaceHostRouter(controller: controller)
        router.showToast = { [weak self] text in
            self?.toasts.showAdHoc(text: text, kind: .error)
        }
        // Drag & drop/transfer seams mirror the legacy sidebar's wiring
        // below; an empty directory id means the root (the flat row list
        // has no explicit root row).
        router.configureTreeView = { [weak self] tree in
            tree.onDropFiles = { [weak self] urls, directory in
                guard let self else { return }
                let dir = directory.isEmpty ? self.projectRoot.path : directory
                self.fileTransfers.importItems(urls, into: dir)
            }
            tree.onMoveItems = { [weak self] paths, directory in
                guard let self else { return }
                let dir = directory.isEmpty ? self.projectRoot.path : directory
                self.fileTransfers.moveItems(paths, into: dir)
            }
            tree.onCancelTransfers = { [weak self] in
                self?.fileTransfers.cancelActiveTransfers()
            }
            tree.dragWriterProvider = { [weak self] path, isDirectory in
                self?.dragWriter(forPath: path, isDirectory: isDirectory)
            }
        }
        return router
    }()

    /// The attached window; UIComponentRouter presents panels/sheets over it.
    var attachedWindow: NSWindow? { window }

    init(
        controller: NvimController,
        projectRoot: URL,
        fileAccess: WorkspaceFileAccess = .local
    ) {
        self.controller = controller
        self.projectRoot = projectRoot
        self.fileAccess = fileAccess
        self.fileIndex = FileIndex(root: projectRoot, source: fileAccess.indexSource)
        self.sidebar = FileTreeSidebarView(lister: fileAccess.lister)
        self.fileTransfers = WorkspaceFileTransferCoordinator(
            transport: fileAccess.transport, lister: fileAccess.lister)
        sidebar.allowsFileOperations = fileAccess.isLocal
        // No change notifications reach a non-local tree; poll on expansion.
        sidebar.refreshesOnExpand = !fileAccess.isLocal
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        self.cmdlinePanel = CmdlinePanelController(font: mono)
        self.popupMenu = PopupMenuPanelController(font: mono)

        chromeState.onChange = { [weak self] in self?.syncChrome() }
        wireShell()
    }

    /// Called once the window exists.
    func attach(window: NSWindow, surface: GridSurfaceView) {
        self.window = window
        self.surface = surface
        toasts.attach(to: window)
        sidebar.setRoot(projectRoot)
        statusBar.render(StatusModel(project: projectRoot.lastPathComponent), dark: isDark)
        Task { await fileIndex.refresh() }
        startWorkspaceWatcher()
    }

    /// Re-roots all native workspace chrome after Neovim changes directory.
    /// Existing buffers remain owned by Neovim; only project-scoped native
    /// state (tree, quick-open index, decorations, and status metadata) is
    /// replaced here.
    func setProjectRoot(_ root: URL) {
        let root = root.standardizedFileURL

        // A palette must not outlive the index or relative-path root that
        // produced its rows. Plugin palettes get their normal close callback;
        // the built-in palette simply dismisses and restores editor focus.
        uiRouter.closePaletteSession()
        cancelQuickOpenQuery()
        workspaceRefreshTask?.cancel()
        workspaceRefreshTask = nil
        fileWatcher.stop()
        quickOpen.close()

        fileIndexGeneration &+= 1
        projectRoot = root
        fileIndex = FileIndex(root: root, source: fileAccess.indexSource)

        sidebar.setGitStatus([:])
        uiRouter.setProjectRoot(root)
        sidebar.setRoot(root)

        var status = statusBar.model
        status.project = root.lastPathComponent
        statusBar.render(status, dark: isDark)

        let index = fileIndex
        Task { await index.refresh() }
        startWorkspaceWatcher()
    }

    // MARK: - Redraw / notification entry points (called by NvimController)

    func apply(_ batch: RedrawBatch) {
        chromeState.apply(batch)
    }

    func handleNotification(_ method: String, _ params: [Value]) {
        switch method {
        case "superlemon.status":
            guard let payload = params.first, payload.mapValue != nil else { return }
            statusBar.render(statusModel(from: payload), dark: isDark)
            controller?.updateEditorCommandState(payload)
        case "superlemon.font":
            let delta = params.first?["delta"]?.intValue ?? 0
            controller?.bumpFont(delta: delta)
        case "superlemon.save_as":
            onSaveAsRequested?()
        case "superlemon.settings":
            guard let payload = params.first, payload.mapValue != nil else { return }
            controller?.applyRuntimeSettings(payload)
        case "superlemon.chrome":
            guard let payload = params.first else { return }
            nativeTabs = payload["native_tabs"]?.boolValue ?? false
            nativeStatusbar = payload["native_statusbar"]?.boolValue ?? false
            nativeMinimap = payload["native_minimap"]?.boolValue ?? true
            nativeScrollbars = payload["native_scrollbars"]?.boolValue ?? false
            nativeSidebar = payload["native_sidebar"]?.boolValue ?? true
            onChromeModeChange?(
                nativeTabs, nativeStatusbar, nativeMinimap, nativeScrollbars,
                nativeSidebar)
            tabStrip.updateAccessoryState(
                sidebarVisible: nativeSidebar, minimapOn: nativeMinimap)
            syncChrome()  // re-route the cmdline if one is active
        case "superlemon.cwd":
            // nvim's global cwd changed (`:cd` inside the editor). Re-root
            // the workspace; GUI-initiated cds echo back through here too,
            // so a same-root notification is a no-op.
            guard let path = params.first?["cwd"]?.stringValue, !path.isEmpty
            else { return }
            let root = URL(fileURLWithPath: path, isDirectory: true)
                .standardizedFileURL
            if root.path != projectRoot.path { setProjectRoot(root) }
        case "superlemon.statusline":
            // The user's own statusline, evaluated by nvim_eval_statusline —
            // rendered natively instead of the built-in chips (CONTRACT.md).
            guard let payload = params.first else { return }
            guard let segmentValues = payload["segments"]?.arrayValue else {
                statusBar.renderStatusline(nil)  // vim.NIL: no custom statusline
                return
            }
            let segments = segmentValues.compactMap { value -> StatuslineSegment? in
                guard let text = value["text"]?.stringValue else { return nil }
                return StatuslineSegment(
                    text: text,
                    fg: value["fg"]?.intValue.map { UInt32(truncatingIfNeeded: $0) },
                    bg: value["bg"]?.intValue.map { UInt32(truncatingIfNeeded: $0) },
                    bold: value["bold"]?.boolValue ?? false,
                    italic: value["italic"]?.boolValue ?? false)
            }
            statusBar.renderStatusline(segments)
        case "superlemon.git":
            // Slim git provider (CONTRACT.md): cwd-relative paths + one-letter
            // statuses → sidebar badges. Empty list clears the badges.
            guard let payload = params.first,
                let fileValues = payload["files"]?.arrayValue
            else { return }
            var statuses: [String: String] = [:]
            for value in fileValues {
                guard let rel = value["path"]?.stringValue,
                    let status = value["status"]?.stringValue
                else { continue }
                statuses[projectRoot.appendingPathComponent(rel).path] = status
            }
            sidebar.setGitStatus(statuses)
        case "superlemon.ui":
            // The component framework (CONTRACT.md, DESIGN §15): surface-mode
            // components peel off to the surface host; everything else goes
            // to the component router.
            var quad = params
            if quad.count == 1, let inner = quad[0].arrayValue { quad = inner }
            if quad.count >= 4,
                let component = quad[0].stringValue,
                let uiMethod = quad[1].stringValue,
                let namespace = quad[2].stringValue,
                surfaceHost.handle(
                    component: component, method: uiMethod,
                    namespace: namespace, args: quad[3])
            {
                return
            }
            uiRouter.handle(params)
        case "superlemon.buffers":
            guard let payload = params.first,
                let bufferValues = payload["buffers"]?.arrayValue
            else { return }
            let tabs = bufferValues.compactMap { value -> BufferTab? in
                guard let bufnr = value["bufnr"]?.intValue else { return nil }
                return BufferTab(
                    bufnr: bufnr,
                    name: value["name"]?.stringValue ?? "",
                    modified: value["modified"]?.boolValue ?? false,
                    preview: value["preview"]?.boolValue ?? false)
            }
            tabStrip.render(
                tabs: tabs, current: payload["current"]?.intValue ?? -1, dark: isDark)
        default:
            break
        }
    }

    func applyAppearance(dark: Bool) {
        statusBar.render(statusBar.model, dark: dark)
        sidebar.applyAppearance(dark: dark)
        quickOpen.applyAppearance(dark: dark)
        tabStrip.applyAppearance(dark: dark)
        surfaceHost.applyAppearance(dark: dark)
    }

    // MARK: - ChromeKit sync

    // See ChromeKit/WIRING.md, “Synchronizing the native surfaces”.

    private func syncChrome() {
        guard let window else { return }

        // Cmdline routing: with the native status bar on, the command line
        // lives IN the bar (powerline-style); otherwise the floating palette.
        cmdlinePanel.font = editorFont  // track editor font/size changes
        if nativeStatusbar {
            cmdlinePanel.render(nil, resolver: highlightResolver)  // dismiss if up
            statusBar.renderCommand(commandLineAttributedString())
        } else {
            statusBar.renderCommand(nil)
            cmdlinePanel.render(chromeState.cmdline, resolver: highlightResolver)
            if chromeState.cmdline != nil {
                cmdlinePanel.present(over: window)
            }
        }

        if let menu = chromeState.popupmenu {
            // Selection-only updates (popupmenu_select) keep the panel where
            // it is; a NEW menu (fresh popupmenu_show: different items or
            // anchor) must RE-ANCHOR — reusing the old frame froze the popup
            // at stale positions across mode toggles and wildmenu reopens.
            let anchorChanged =
                lastPumIdentity == nil
                || lastPumIdentity! != PumIdentity(
                    items: menu.items, grid: menu.grid, row: menu.row, col: menu.col)
            if popupMenu.isPresented && !anchorChanged {
                popupMenu.render(menu)
            } else {
                popupMenu.present(
                    anchoredAt: anchorPoint(grid: menu.grid, row: menu.row, col: menu.col),
                    in: window, model: menu)
            }
            lastPumIdentity = PumIdentity(
                items: menu.items, grid: menu.grid, row: menu.row, col: menu.col)
        } else {
            popupMenu.render(nil)
            lastPumIdentity = nil
        }

        toasts.render(chromeState.messages)

        if let confirm = chromeState.pendingConfirm {
            chromeState.clearPendingConfirm()
            presentConfirmAlert(confirm)
        }
    }

    /// The active cmdline as one attributed line for the status bar's
    /// command segment: firstc (":", "/", …) + rendered content chunks.
    /// The editor's current font (name + size from the surface's FontSpec) —
    /// the command line matches the editor, not a fixed chrome size.
    private var editorFont: NSFont {
        let spec = surface?.fontSpec ?? FontSpec()
        return spec.name.flatMap { NSFont(name: $0, size: spec.size) }
            ?? .monospacedSystemFont(ofSize: spec.size, weight: .regular)
    }

    private func commandLineAttributedString() -> NSAttributedString? {
        guard let model = chromeState.cmdline else { return nil }
        let font = editorFont
        let line = NSMutableAttributedString()
        let prompt = model.firstc.isEmpty ? model.prompt : model.firstc
        if !prompt.isEmpty {
            line.append(NSAttributedString(
                string: prompt,
                attributes: [
                    .font: font,
                    .foregroundColor: highlightResolver(0).fg.withAlphaComponent(0.6),
                ]))
        }
        line.append(CmdlineRenderer.contentLine(
            for: model, font: font, resolver: highlightResolver))
        return line
    }

    /// GridKit-backed resolver (ChromeKit/WIRING.md “Highlight resolution”):
    /// id 0 = the default pair.
    private var highlightResolver: HighlightResolver {
        guard let highlights = controller?.store.highlights else {
            // Torn-down host: no live grid store to resolve against.
            return { _ in (.labelColor, .windowBackgroundColor) }
        }
        return { hlID in
            let resolved = highlights.resolved(id: hlID)
            return (nsColor(resolved.foreground), nsColor(resolved.background))
        }
    }

    /// Grid cell → contentView point for the popupmenu (ChromeKit/WIRING.md
    /// “Grid cell to popup anchor”).
    private func anchorPoint(grid: Int, row: Int, col: Int) -> NSPoint {
        guard let window, let contentView = window.contentView else { return .zero }
        if grid == -1 {
            if nativeStatusbar {
                // Cmdline lives IN the bottom bar: anchor at the bar's top
                // edge so the popup's flip logic opens it UPWARD (downward
                // would descend below the window, under the dock).
                return NSPoint(x: statusBar.frame.minX + 8, y: statusBar.frame.maxY)
            }
            // Wildmenu: anchor under the floating cmdline panel. The panel
            // is its OWN window — its frame is in SCREEN coordinates and
            // must round-trip through the host window (treating it as
            // window-local put the popup at the bottom of the window,
            // nowhere near the cmdline).
            let screenFrame = cmdlinePanel.panel.frame
            let inWindow = window.convertFromScreen(screenFrame)
            let panelFrame = contentView.convert(inWindow, from: nil)
            return NSPoint(x: panelFrame.minX + 16, y: panelFrame.minY - 2)
        }
        guard let surface, let gridRect = surface.rect(ofGrid: grid) else { return .zero }
        // Surface is flipped (top-left origin); convert() handles the flip.
        let cellTopLeft = NSPoint(
            x: gridRect.minX + CGFloat(col) * surface.cellSize.width,
            y: gridRect.minY + CGFloat(row) * surface.cellSize.height)
        return surface.convert(cellTopLeft, to: contentView)
    }

    /// ext_messages `confirm` → native sheet (ChromeKit/WIRING.md “Messages
    /// and confirmations”). Buttons are
    /// parsed from nvim's "&Yes\n&No\n&Cancel"-style prompt text; each reply
    /// is the button's hotkey via nvim_input.
    private func presentConfirmAlert(_ confirm: MessageModel) {
        guard let window, !confirmAlertShowing else { return }
        confirmAlertShowing = true

        let text = confirm.content.joinedText
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // nvim renders choices in the last line, e.g. "[Y]es, (N)o, (C)ancel: ".
        let message = lines.dropLast().joined(separator: "\n")
        let choiceLine = String(lines.last ?? "")
        let choices = Self.parseChoices(from: choiceLine)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message.isEmpty ? choiceLine : message
        for choice in choices { alert.addButton(withTitle: choice.title) }
        if choices.isEmpty { alert.addButton(withTitle: "OK") }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.confirmAlertShowing = false
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if index >= 0, index < choices.count {
                self.controller?.sendInput(choices[index].key)
            } else {
                self.controller?.sendInput("<Esc>")
            }
        }
    }

    /// "[Y]es, (N)o, (C)ancel: " → [("Yes","y"), ("No","n"), ("Cancel","c")].
    static func parseChoices(from line: String) -> [(title: String, key: String)] {
        var choices: [(String, String)] = []
        for raw in line.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let part = raw.trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            guard let open = part.firstIndex(where: { $0 == "[" || $0 == "(" }),
                let hotkey = part.index(open, offsetBy: 1, limitedBy: part.endIndex)
                    .flatMap({ $0 < part.endIndex ? part[$0] : nil })
            else { continue }
            let title = part.replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .replacingOccurrences(of: "(", with: "")
                .replacingOccurrences(of: ")", with: "")
            choices.append((title, String(hotkey).lowercased()))
        }
        return choices
    }

    // MARK: - ShellKit wiring (WIRING.md)

    private func wireShell() {
        quickOpen.onQueryChange = { [weak self] query in
            self?.queryQuickOpen(query)
        }
        quickOpen.onOpen = { [weak self] relativePath in
            self?.openQuickOpenSelection(relativePath)
        }
        quickOpen.onClose = { [weak self] in
            self?.cancelQuickOpenQuery()
            self?.restoreFocus?()
        }

        tabStrip.onSelect = { [weak self] bufnr in
            self?.controller?.switchToBuffer(bufnr)
            self?.restoreFocus?()
        }
        tabStrip.onClose = { [weak self] bufnr in
            self?.controller?.closeBuffer(bufnr)
            self?.restoreFocus?()
        }
        tabStrip.onPromote = { [weak self] bufnr in
            self?.controller?.promoteBuffer(bufnr)
            self?.restoreFocus?()
        }
        // Sidebar/minimap visibility round-trips through nvim (the source of
        // truth); the resulting superlemon.chrome push updates the layout
        // and the buttons' state.
        tabStrip.onToggleSidebar = { [weak self] in
            self?.controller?.toggleNativeChrome("sidebar")
        }
        tabStrip.onToggleMinimap = { [weak self] in
            self?.controller?.toggleNativeChrome("minimap")
        }

        // VS Code/Sublime semantics: single-click previews (italic tab,
        // replaced by the next preview); double-click opens permanently.
        sidebar.onOpenFile = { [weak self] absolutePath in
            self?.controller?.previewFile(absolutePath)
        }
        sidebar.onOpenFilePermanently = { [weak self] absolutePath in
            self?.controller?.openFilePermanently(absolutePath)
        }
        sidebar.onRequestEditorFocus = { [weak self] in
            self?.restoreFocus?()
        }
        sidebar.onRequestCreateItem = { [weak self] directory, kind in
            self?.presentCreatePrompt(in: directory, kind: kind)
        }
        // ".." row and the folder context menu: cd inside nvim; the tree
        // re-roots via getcwd readback (and superlemon.cwd for external cds).
        sidebar.onChangeWorkingDirectory = { [weak self] absolutePath in
            self?.controller?.openFolder(absolutePath)
        }
        sidebar.onFileOperation = { [weak self] op in
            guard let self else { return }
            switch op {
            case .revealInFinder(let path):
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                self.restoreFocus?()
            case .rename(let path, _), .trash(let path):
                self.performFileOperation(
                    op, reloadPath: (path as NSString).deletingLastPathComponent)
            case .newFile(let dir, _), .newFolder(let dir, _):
                self.performFileOperation(op, reloadPath: dir)
            }
        }
        fileWatcher.onChange = { [weak self] batch in
            self?.workspaceFilesChanged(batch)
        }

        // Drag & drop: drops import, internal drags move, row drags export.
        sidebar.onDropFiles = { [weak self] urls, directory in
            self?.fileTransfers.importItems(urls, into: directory)
        }
        sidebar.onMoveItems = { [weak self] paths, directory in
            self?.fileTransfers.moveItems(paths, into: directory)
        }
        sidebar.onCancelTransfers = { [weak self] in
            self?.fileTransfers.cancelActiveTransfers()
        }
        sidebar.dragWriterProvider = { [weak self] path, isDirectory in
            self?.dragWriter(forPath: path, isDirectory: isDirectory)
        }
        fileTransfers.onProgress = { [weak self] progress in
            self?.surfaceHost.treeView?.renderTransferProgress(progress)
        }
        fileTransfers.onError = { [weak self] message in
            self?.presentTransferError(message)
        }
        fileTransfers.onWorkspaceChanged = { [weak self] directories in
            self?.workspaceTransferChanged(directories)
        }
        fileTransfers.resolveConflicts = { [weak self] names in
            await self?.confirmTransferConflicts(names) ?? .cancel
        }
    }

    // MARK: - Drag & drop wiring

    /// Local workspaces drag real file URLs (Finder performs the copy
    /// itself); remote workspaces drag file promises whose fulfillment
    /// streams a download through the transfer coordinator.
    private func dragWriter(forPath path: String, isDirectory: Bool) -> NSPasteboardWriting? {
        if fileAccess.isLocal {
            return URL(fileURLWithPath: path, isDirectory: isDirectory) as NSURL
        }
        let delegate = remoteDragPromiseDelegate ?? RemoteDragPromiseDelegate(
            exporter: { [weak self] path, isDirectory, destination in
                guard let self else { throw CocoaError(.fileNoSuchFile) }
                try await self.fileTransfers.exportItem(
                    at: path, isDirectory: isDirectory, to: destination)
            })
        remoteDragPromiseDelegate = delegate
        let type: UTType = isDirectory
            ? .folder
            : UTType(filenameExtension: (path as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.userInfo = RemoteDragPromiseDelegate.Payload(
            path: path, isDirectory: isDirectory)
        return provider
    }

    /// A finished batch is authoritative about what changed: reload those
    /// directories and rebuild the quick-open index (FSEvents also fires
    /// for local workspaces; the explicit reload keeps remote trees honest).
    private func workspaceTransferChanged(_ directories: Set<String>) {
        for directory in directories {
            sidebar.reload(path: directory)
        }
        workspaceRefreshTask?.cancel()
        let generation = fileIndexGeneration
        let index = fileIndex
        workspaceRefreshTask = Task { [weak self] in
            await index.refresh()
            guard !Task.isCancelled, let self,
                generation == self.fileIndexGeneration
            else { return }
            self.workspaceRefreshTask = nil
        }
    }

    private func confirmTransferConflicts(
        _ names: [String]
    ) async -> WorkspaceFileTransferCoordinator.ConflictResolution {
        guard let window else { return .keepBoth }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            names.count == 1
            ? "“\(names[0])” already exists in this folder"
            : "\(names.count) items already exist in this folder"
        let shown = names.prefix(6).joined(separator: "\n")
        alert.informativeText =
            (names.count > 6 ? shown + "\n… and \(names.count - 6) more" : shown)
            + "\n\nKeep Both adds a numbered copy; Replace overwrites the existing items."
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                switch response {
                case .alertFirstButtonReturn:
                    continuation.resume(returning: .keepBoth)
                case .alertSecondButtonReturn:
                    continuation.resume(returning: .replace)
                default:
                    continuation.resume(returning: .cancel)
                }
            }
        }
    }

    private func presentTransferError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Transfer Files"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func queryQuickOpen(_ query: String) {
        quickOpenQueryTask?.cancel()
        quickOpenQueryGeneration &+= 1
        let queryGeneration = quickOpenQueryGeneration
        let indexGeneration = fileIndexGeneration
        let presentationGeneration = quickOpen.presentationGeneration
        let index = fileIndex

        quickOpenQueryTask = Task { [weak self] in
            let response = await index.search(query)
            guard !Task.isCancelled, let self,
                queryGeneration == self.quickOpenQueryGeneration,
                indexGeneration == self.fileIndexGeneration,
                presentationGeneration == self.quickOpen.presentationGeneration,
                self.quickOpen.sessionActive,
                self.quickOpen.query == query
            else { return }
            _ = self.quickOpen.display(
                results: response.matches.map {
                    QuickOpenResult(path: $0.path, positions: $0.positions)
                },
                totalCount: response.totalCount,
                isTruncated: response.isTruncated,
                matchingCount: query.isEmpty ? nil : response.matchingCount,
                presentationGeneration: presentationGeneration)
            self.quickOpenQueryTask = nil
        }
    }

    private func cancelQuickOpenQuery() {
        quickOpenQueryGeneration &+= 1
        quickOpenQueryTask?.cancel()
        quickOpenQueryTask = nil
    }

    /// A displayed result can become stale between an FSEvents batch and the
    /// user's Return key. Revalidate it off the main actor, then reject both
    /// an obsolete workspace generation and a deleted/directory result before
    /// asking Neovim to open anything.
    private func openQuickOpenSelection(_ relativePath: String) {
        guard fileAccess.isLocal else {
            // The local stat below reads the wrong filesystem for a remote
            // session. Containment is pure path logic and still applies;
            // existence is nvim's to judge (openFile surfaces its error).
            do {
                let url = try Self.containedQuickOpenURL(
                    relativePath: relativePath, projectRoot: projectRoot)
                controller?.openFile(url.path)
            } catch let error as QuickOpenSelectionError {
                presentQuickOpenSelectionError(error)
            } catch {}
            return
        }
        let generation = fileIndexGeneration
        let root = projectRoot
        let index = fileIndex
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<URL, QuickOpenSelectionError>.success(
                        try Self.validatedQuickOpenURL(
                            relativePath: relativePath, projectRoot: root))
                } catch let error as QuickOpenSelectionError {
                    return .failure(error)
                } catch {
                    return .failure(.notAFile(relativePath))
                }
            }.value
            guard let self, generation == self.fileIndexGeneration,
                root == self.projectRoot
            else { return }

            switch result {
            case .success(let url):
                // Re-checked post-suspension: the embedding host may have
                // torn the controller down while the stat hopped off-actor.
                guard let controller = self.controller else { return }
                controller.openFile(url.path)
            case .failure(let error):
                await index.refresh()
                guard generation == self.fileIndexGeneration else { return }
                self.presentQuickOpenSelectionError(error)
            }
        }
    }

    /// Path containment only — no filesystem access, so it is also valid for
    /// paths on a remote session's filesystem.
    nonisolated static func containedQuickOpenURL(
        relativePath: String, projectRoot: URL
    ) throws -> URL {
        let root = projectRoot.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.path
        guard candidate.path != rootPath,
            candidate.path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
        else {
            throw QuickOpenSelectionError.outsideWorkspace(candidate.path)
        }
        return candidate
    }

    nonisolated static func validatedQuickOpenURL(
        relativePath: String, projectRoot: URL
    ) throws -> URL {
        let candidate = try containedQuickOpenURL(
            relativePath: relativePath, projectRoot: projectRoot)
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(
            atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else {
            throw QuickOpenSelectionError.notAFile(candidate.path)
        }
        return candidate
    }

    private func presentQuickOpenSelectionError(_ error: QuickOpenSelectionError) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t Open Quick Open Result"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
    }

    private func performFileOperation(
        _ operation: FileOperation,
        reloadPath: String,
        restoreEditorFocus: Bool = true,
        onSuccess: ((String?) async -> Void)? = nil,
        onFailure: ((String) -> Void)? = nil
    ) {
        let generation = fileIndexGeneration
        let index = fileIndex
        Task { [weak self] in
            guard let self else { return }
            let result = await self.fileMutationQueue.perform(operation)
            guard generation == self.fileIndexGeneration else {
                if restoreEditorFocus { self.restoreFocus?() }
                return
            }
            if result.succeeded {
                self.sidebar.reload(path: reloadPath)
                await index.refresh()
                guard generation == self.fileIndexGeneration else {
                    if restoreEditorFocus { self.restoreFocus?() }
                    return
                }
                await self.sidebar.waitForPendingLoads()
                await onSuccess?(result.resultingPath)
            } else if let description = result.errorDescription {
                if case .rename(let path, _) = operation {
                    self.sidebar.rollbackInlineRename(path: path)
                }
                if let onFailure {
                    onFailure(description)
                } else {
                    self.presentFileOperationError(operation, description: description)
                }
            }
            if restoreEditorFocus { self.restoreFocus?() }
        }
    }

    private func presentCreatePrompt(
        in directory: String,
        kind: FileTreeCreateKind,
        proposedName: String = "",
        errorDescription: String? = nil
    ) {
        let noun = kind == .file ? "File" : "Folder"
        let alert = NSAlert()
        alert.messageText = "New \(noun)"
        alert.informativeText = errorDescription ?? "Enter a name for the new \(noun.lowercased())."
        if errorDescription != nil { alert.alertStyle = .warning }
        let nameField = NSTextField(string: proposedName)
        nameField.placeholderString = kind == .file ? "example.swift" : "Folder name"
        nameField.frame.size = NSSize(width: 320, height: 24)
        nameField.setAccessibilityLabel("New \(noun) name")
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let submit: (NSApplication.ModalResponse) -> Void = { [weak self, weak nameField] response in
            guard response == .alertFirstButtonReturn, let self, let nameField else {
                self?.restoreFocus?()
                return
            }
            let name = nameField.stringValue
            do {
                _ = try FileOperations.validateName(name)
            } catch {
                self.presentCreatePrompt(
                    in: directory, kind: kind, proposedName: name,
                    errorDescription: error.localizedDescription)
                return
            }

            let operation: FileOperation = kind == .file
                ? .newFile(directory: directory, name: name)
                : .newFolder(directory: directory, name: name)
            self.performFileOperation(
                operation,
                reloadPath: directory,
                restoreEditorFocus: false,
                onSuccess: { [weak self] resultingPath in
                    guard let self, let resultingPath else { return }
                    if !self.sidebar.selectItem(
                        path: resultingPath, focus: kind == .folder)
                    {
                        _ = await self.sidebar.revealCreatedItem(
                            path: resultingPath, focus: kind == .folder)
                    }
                    if kind == .file {
                        // Re-checked: `revealCreatedItem` above may have
                        // suspended long enough for the host to tear the
                        // controller down.
                        self.controller?.openFilePermanently(resultingPath)
                        self.restoreFocus?()
                    }
                },
                onFailure: { [weak self] description in
                    self?.presentCreatePrompt(
                        in: directory, kind: kind, proposedName: name,
                        errorDescription: description)
                })
        }

        if let window {
            alert.beginSheetModal(for: window, completionHandler: submit)
            DispatchQueue.main.async { [weak alert, weak nameField] in
                guard let alert, let nameField else { return }
                alert.window.makeFirstResponder(nameField)
                nameField.currentEditor()?.selectAll(nil)
            }
        } else {
            submit(alert.runModal())
        }
    }

    private func startWorkspaceWatcher() {
        // FSEvents watches this machine's filesystem only. A non-local tree
        // polls instead: directories refresh on expansion and the quick-open
        // index refreshes when the palette is presented.
        guard fileAccess.isLocal else { return }
        do {
            try fileWatcher.start(watching: projectRoot)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Workspace Monitoring Unavailable"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    private func workspaceFilesChanged(_ batch: WorkspaceFileChangeBatch) {
        let gitPath = projectRoot.appendingPathComponent(".git").path
        let relevantPaths = Set(batch.paths.filter {
            $0 != gitPath && !$0.hasPrefix(gitPath + "/")
        })
        guard !relevantPaths.isEmpty || batch.requiresFullRescan else { return }

        workspaceRefreshTask?.cancel()
        let generation = fileIndexGeneration
        let index = fileIndex
        sidebar.reload(
            changedPaths: relevantPaths,
            requiresFullRescan: batch.requiresFullRescan)
        workspaceRefreshTask = Task { [weak self] in
            await index.refresh()
            guard !Task.isCancelled, let self,
                generation == self.fileIndexGeneration
            else { return }
            self.workspaceRefreshTask = nil
        }
    }

    private func presentFileOperationError(_ operation: FileOperation, description: String) {
        let action: String
        switch operation {
        case .newFile: action = "Create File"
        case .newFolder: action = "Create Folder"
        case .rename: action = "Rename Item"
        case .trash: action = "Move Item to Trash"
        case .revealInFinder: return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t \(action)"
        alert.informativeText = description
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    public func presentQuickOpen() {
        // ⌘P during a plugin palette session: end the session first so the
        // built-in file-picker wiring (restored on session close) is live.
        uiRouter.closePaletteSession()
        quickOpen.present(over: window)
        guard !fileAccess.isLocal else { return }
        // No FSEvents reach a remote filesystem, so the index refreshes when
        // the palette opens: stale results show instantly, and the active
        // query re-runs once the fresh listing lands.
        refreshQuickOpenIndexWithoutWatcher()
    }

    private func refreshQuickOpenIndexWithoutWatcher() {
        workspaceRefreshTask?.cancel()
        let generation = fileIndexGeneration
        let presentationGeneration = quickOpen.presentationGeneration
        let index = fileIndex
        workspaceRefreshTask = Task { [weak self] in
            await index.refresh()
            guard !Task.isCancelled, let self,
                generation == self.fileIndexGeneration
            else { return }
            self.workspaceRefreshTask = nil
            guard self.quickOpen.sessionActive,
                presentationGeneration == self.quickOpen.presentationGeneration
            else { return }
            self.queryQuickOpen(self.quickOpen.query)
        }
    }

    // MARK: - helpers

    private var isDark: Bool {
        window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func statusModel(from payload: Value) -> StatusModel {
        StatusModel(
            mode: StatusMode(rawNvimMode: payload["mode"]?.stringValue ?? "n"),
            file: payload["file"]?.stringValue ?? "",
            modified: payload["modified"]?.boolValue ?? false,
            branch: payload["branch"]?.stringValue ?? "",
            line: payload["line"]?.intValue ?? 1,
            col: payload["col"]?.intValue ?? 1,
            totalLines: payload["total_lines"]?.intValue ?? 1,
            project: payload["project"]?.stringValue ?? "")
    }
}

/// Fulfills remote drag-out promises. AppKit calls the delegate on its
/// fulfillment queue; the export itself hops to the main actor and streams
/// through the transfer coordinator. One shared instance serves every
/// provider; the dragged item's identity travels in `userInfo`.
private final class RemoteDragPromiseDelegate: NSObject, NSFilePromiseProviderDelegate,
    @unchecked Sendable
{
    struct Payload: Sendable {
        let path: String
        let isDirectory: Bool
    }

    typealias Exporter = @MainActor @Sendable (
        _ path: String, _ isDirectory: Bool, _ destination: URL
    ) async throws -> Void

    private let exporter: Exporter
    private let fulfillmentQueue = OperationQueue()

    init(exporter: @escaping Exporter) {
        self.exporter = exporter
        fulfillmentQueue.maxConcurrentOperationCount = 1
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String
    ) -> String {
        guard let payload = filePromiseProvider.userInfo as? Payload else { return "file" }
        return (payload.path as NSString).lastPathComponent
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        fulfillmentQueue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        guard let payload = filePromiseProvider.userInfo as? Payload else {
            completionHandler(CocoaError(.fileNoSuchFile))
            return
        }
        let exporter = self.exporter
        Task {
            do {
                try await exporter(payload.path, payload.isDirectory, url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

private func nsColor(_ color: NvimKit.RGBColor) -> NSColor {
    NSColor(
        srgbRed: CGFloat((color.rgb >> 16) & 0xFF) / 255,
        green: CGFloat((color.rgb >> 8) & 0xFF) / 255,
        blue: CGFloat(color.rgb & 0xFF) / 255,
        alpha: 1)
}
