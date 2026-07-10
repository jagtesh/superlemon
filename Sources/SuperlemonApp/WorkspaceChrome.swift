// WorkspaceChrome — owns every wave-3 chrome component and its wiring:
// ChromeKit (cmdline palette, popupmenu, toasts, confirm alerts), ShellKit
// (sidebar, status bar, quick-open), and the superlemon.* RPC notifications.
// See Sources/ChromeKit/WIRING.md and Sources/ShellKit/WIRING.md.

import AppKit
import ChromeKit
import GridKit
import NvimKit
import ShellKit
import SurfaceKit

@MainActor
final class WorkspaceChrome {
    let chromeState = ChromeState()
    let cmdlinePanel: CmdlinePanelController
    let popupMenu: PopupMenuPanelController
    let toasts = MessageToastController()

    let statusBar = StatusBarView()
    let sidebar = FileTreeSidebarView()
    let quickOpen = QuickOpenPanelController()
    let tabStrip = BufferTabStripView()
    let fileIndex: FileIndex

    /// Native-chrome toggles, mirrored from nvim (`superlemon.chrome` —
    /// nvim is the source of truth). The app delegate resizes the layout.
    var onChromeModeChange: ((_ nativeTabs: Bool, _ nativeStatusbar: Bool) -> Void)?
    private(set) var nativeTabs = false
    private(set) var nativeStatusbar = false

    private unowned let controller: NvimController
    private weak var window: NSWindow?
    private weak var surface: GridSurfaceView?
    private let projectRoot: URL
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

    /// The attached window; UIComponentRouter presents panels/sheets over it.
    var attachedWindow: NSWindow? { window }

    init(controller: NvimController, projectRoot: URL) {
        self.controller = controller
        self.projectRoot = projectRoot
        self.fileIndex = FileIndex(root: projectRoot)
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
        statusBar.synthesizePowerline = UserDefaults.standard.bool(forKey: "PowerlineGlyphs")
        sidebar.setRoot(projectRoot)
        statusBar.render(StatusModel(project: projectRoot.lastPathComponent), dark: isDark)
        Task { await fileIndex.refresh() }
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
        case "superlemon.font":
            let delta = params.first?["delta"]?.intValue ?? 0
            controller.bumpFont(delta: delta)
        case "superlemon.chrome":
            guard let payload = params.first else { return }
            nativeTabs = payload["native_tabs"]?.boolValue ?? false
            nativeStatusbar = payload["native_statusbar"]?.boolValue ?? false
            onChromeModeChange?(nativeTabs, nativeStatusbar)
            syncChrome()  // re-route the cmdline if one is active
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
            // The component framework (CONTRACT.md, DESIGN §15): one generic
            // notification routed to the native components.
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
    }

    // MARK: - ChromeKit sync (WIRING.md §2)

    private func syncChrome() {
        guard let window else { return }

        // Cmdline routing: with the native status bar on, the command line
        // lives IN the bar (powerline-style); otherwise the floating palette.
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
    private func commandLineAttributedString() -> NSAttributedString? {
        guard let model = chromeState.cmdline else { return nil }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
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

    /// GridKit-backed resolver (WIRING.md §3): id 0 = the default pair.
    private var highlightResolver: HighlightResolver {
        let highlights = controller.store.highlights
        return { hlID in
            let resolved = highlights.resolved(id: hlID)
            return (nsColor(resolved.foreground), nsColor(resolved.background))
        }
    }

    /// Grid cell → contentView point for the popupmenu (WIRING.md §4).
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

    /// ext_messages `confirm` → native sheet (WIRING.md §5). Buttons are
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
                self.controller.sendInput(choices[index].key)
            } else {
                self.controller.sendInput("<Esc>")
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
            guard let self else { return }
            Task {
                let results = await self.fileIndex.query(query)
                let total = await self.fileIndex.count()
                self.quickOpen.display(
                    results: results.map { QuickOpenResult(path: $0.path, positions: $0.positions) },
                    totalCount: total)
            }
        }
        quickOpen.onOpen = { [weak self] relativePath in
            guard let self else { return }
            self.controller.openFile(self.projectRoot.appendingPathComponent(relativePath).path)
        }
        quickOpen.onClose = { [weak self] in
            self?.restoreFocus?()
        }

        tabStrip.onSelect = { [weak self] bufnr in
            self?.controller.switchToBuffer(bufnr)
        }
        tabStrip.onClose = { [weak self] bufnr in
            self?.controller.closeBuffer(bufnr)
        }
        tabStrip.onPromote = { [weak self] bufnr in
            self?.controller.promoteBuffer(bufnr)
        }

        // VS Code/Sublime semantics: single-click previews (italic tab,
        // replaced by the next preview); double-click opens permanently.
        sidebar.onOpenFile = { [weak self] absolutePath in
            self?.controller.previewFile(absolutePath)
        }
        sidebar.onOpenFilePermanently = { [weak self] absolutePath in
            self?.controller.openFilePermanently(absolutePath)
        }
        sidebar.onFileOperation = { [weak self] op in
            guard let self else { return }
            switch op {
            case .revealInFinder(let path):
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            case .rename(let path, _), .trash(let path):
                try? FileOperations.perform(op)
                self.sidebar.reload(path: (path as NSString).deletingLastPathComponent)
                Task { await self.fileIndex.refresh() }
            case .newFile(let dir, _), .newFolder(let dir, _):
                try? FileOperations.perform(op)
                self.sidebar.reload(path: dir)
                Task { await self.fileIndex.refresh() }
            }
        }
    }

    func presentQuickOpen() {
        // ⌘P during a plugin palette session: end the session first so the
        // built-in file-picker wiring (restored on session close) is live.
        uiRouter.closePaletteSession()
        quickOpen.present(over: window)
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

private func nsColor(_ color: NvimKit.RGBColor) -> NSColor {
    NSColor(
        srgbRed: CGFloat((color.rgb >> 16) & 0xFF) / 255,
        green: CGFloat((color.rgb >> 8) & 0xFF) / 255,
        blue: CGFloat(color.rgb & 0xFF) / 255,
        alpha: 1)
}
