// UIComponentRouter — the GUI half of the superlemon.ui component
// framework (runtime/CONTRACT.md "superlemon.ui", DESIGN §15): routes the
// one generic `superlemon.ui` notification `[component, method, namespace,
// args]` to the native components (sidebar decorations, palette sessions,
// toasts, statusbar segments, input prompts) and drives Lua callbacks back
// through `require('superlemon.ui')._dispatch`.
//
// Malformed payloads are logged and dropped — never crash. Decoding is
// structured as pure static functions; the composition and hex-parsing
// logic it leans on lives in ShellKit (UIDecorations.swift) where it is
// unit-tested.

import AppKit
import ChromeKit
import NvimKit
import ShellKit
import os

@MainActor
final class UIComponentRouter {

    private unowned let chrome: WorkspaceChrome
    private unowned let controller: NvimController
    private var projectRoot: URL
    private let logger = Logger(subsystem: "com.superlemon.app", category: "ui")

    /// Namespace-isolated sidebar state; composition rule (sorted by
    /// namespace name, later wins per path) lives in the store.
    private var sidebarDecorations = SidebarDecorationStore()

    init(chrome: WorkspaceChrome, controller: NvimController, projectRoot: URL) {
        self.chrome = chrome
        self.controller = controller
        self.projectRoot = projectRoot.standardizedFileURL
    }

    /// Updates the base used to resolve cwd-relative component paths. Native
    /// sidebar decorations belong to the old workspace and are discarded;
    /// plugins can republish them for the new root.
    func setProjectRoot(_ root: URL) {
        projectRoot = root.standardizedFileURL
        sidebarDecorations = SidebarDecorationStore()
        pushSidebarDecorations()
    }

    // MARK: - Entry point

    /// `superlemon.ui` notification params: `[component, method, namespace,
    /// args]` (args a map). Tolerates the whole quad arriving wrapped in a
    /// single array param.
    func handle(_ params: [Value]) {
        var params = params
        if params.count == 1, let inner = params[0].arrayValue {
            params = inner
        }
        guard params.count >= 4,
            let component = params[0].stringValue,
            let method = params[1].stringValue,
            let namespace = params[2].stringValue
        else {
            logger.error("superlemon.ui: malformed payload (\(params.count) params)")
            return
        }
        let args = params[3]

        switch (component, method) {
        case ("sidebar", "set_badge"):
            guard let path = args["path"]?.stringValue,
                let text = args["text"]?.stringValue
            else { return logMalformed(component, method) }
            sidebarDecorations.set(
                SidebarDecoration(kind: .badge(text), color: parseColor(args["color"])),
                path: absolutePath(path), namespace: namespace)
            pushSidebarDecorations()

        case ("sidebar", "set_dot"):
            guard let path = args["path"]?.stringValue,
                let color = parseColor(args["color"])
            else { return logMalformed(component, method) }
            sidebarDecorations.set(
                SidebarDecoration(kind: .dot, color: color),
                path: absolutePath(path), namespace: namespace)
            pushSidebarDecorations()

        case ("sidebar", "clear"):
            sidebarDecorations.clear(namespace: namespace)
            pushSidebarDecorations()

        case ("palette", "open"):
            openPalette(args)

        case ("palette", "close"):
            closePaletteSession()

        case ("toast", "show"):
            guard let text = args["text"]?.stringValue else {
                return logMalformed(component, method)
            }
            let kind = args["kind"]?.stringValue.flatMap(ToastKind.init(rawValue:)) ?? .info
            chrome.toasts.showAdHoc(text: text, kind: kind)

        case ("statusbar", "set_segment"):
            guard let text = args["text"]?.stringValue else {
                return logMalformed(component, method)
            }
            chrome.statusBar.setPluginSegment(
                namespace: namespace, text: text, color: parseColor(args["color"]))

        case ("statusbar", "clear"):
            chrome.statusBar.clearPluginSegment(namespace: namespace)

        case ("input", "open"):
            openInput(args)

        default:
            logger.error(
                "superlemon.ui: unknown \(component, privacy: .public).\(method, privacy: .public)")
        }
    }

    // MARK: - Sidebar

    private func pushSidebarDecorations() {
        chrome.sidebar.setUIDecorations(sidebarDecorations.composed)
    }

    /// Wire paths are cwd-relative (the sidebar keys by absolute path, same
    /// as the superlemon.git handler).
    private func absolutePath(_ relative: String) -> String {
        projectRoot.appendingPathComponent(relative).path
    }

    // MARK: - Palette sessions

    /// One live `palette open` session: the plugin's callback ids, the raw
    /// id per displayed row, and the built-in ⌘P wiring saved for restore.
    @MainActor
    private final class PaletteSession {
        let queryCb: Int
        let selectCb: Int
        let closeCb: Int?
        /// Raw `id` Value per displayed row (int or string — kept opaque).
        var rowIDs: [Value] = []
        /// Monotonic token so stale query round-trips never clobber newer
        /// results.
        var latestQuery = 0

        // The built-in ⌘P file-picker wiring, restored when this session
        // ends (the built-in picker itself is untouched by palette sessions).
        let savedOnQueryChange: ((String) -> Void)?
        let savedOnOpen: ((String) -> Void)?
        let savedOnOpenIndex: ((Int) -> Void)?
        let savedOnClose: (() -> Void)?
        let savedPlaceholder: String

        init(queryCb: Int, selectCb: Int, closeCb: Int?, quickOpen: QuickOpenPanelController) {
            self.queryCb = queryCb
            self.selectCb = selectCb
            self.closeCb = closeCb
            self.savedOnQueryChange = quickOpen.onQueryChange
            self.savedOnOpen = quickOpen.onOpen
            self.savedOnOpenIndex = quickOpen.onOpenIndex
            self.savedOnClose = quickOpen.onClose
            self.savedPlaceholder = quickOpen.placeholder
        }
    }

    private var paletteSession: PaletteSession?

    /// True while a plugin palette session drives the quick-open panel.
    var paletteSessionActive: Bool { paletteSession != nil }

    private func openPalette(_ args: Value) {
        guard let queryCb = args["query_cb"]?.intValue,
            let selectCb = args["select_cb"]?.intValue
        else { return logMalformed("palette", "open") }

        // A second `open` replaces any live session (closing it fires its
        // close_cb, per the contract's close semantics).
        closePaletteSession()

        let quickOpen = chrome.quickOpen
        let session = PaletteSession(
            queryCb: queryCb, selectCb: selectCb,
            closeCb: args["close_cb"]?.intValue, quickOpen: quickOpen)
        paletteSession = session

        quickOpen.placeholder = args["placeholder"]?.stringValue ?? "Search"
        quickOpen.onQueryChange = { [weak self] query in
            self?.paletteQueryChanged(query)
        }
        quickOpen.onOpenIndex = { [weak self] row in
            self?.paletteRowOpened(row)
        }
        quickOpen.onOpen = { _ in }  // path-based open: plugin rows use ids
        quickOpen.onClose = { [weak self] in
            self?.paletteSessionClosed()
        }
        // present() fires onQueryChange("") → the initial query round-trip.
        quickOpen.present(over: chrome.attachedWindow)
    }

    /// `palette close` / session teardown: dismissing the panel triggers
    /// `onClose` → `paletteSessionClosed()` which frees the session.
    func closePaletteSession() {
        guard paletteSession != nil else { return }
        chrome.quickOpen.close()
        // close() fires onClose synchronously; if the panel was somehow
        // never active, fall back to explicit teardown.
        if paletteSession != nil { paletteSessionClosed() }
    }

    private func paletteQueryChanged(_ query: String) {
        guard let session = paletteSession else { return }
        session.latestQuery += 1
        let token = session.latestQuery
        Task { [weak self] in
            guard let self else { return }
            let reply = await self.controller.dispatchUICallback(
                session.queryCb, payload: [(.string("query"), .string(query))])
            // Drop the reply if the session ended or a newer query landed.
            guard self.paletteSession === session, session.latestQuery == token else { return }
            guard let rows = Self.decodePaletteRows(reply) else {
                if reply != nil {
                    self.logger.error("superlemon.ui: palette query_cb returned a non-array")
                }
                return
            }
            session.rowIDs = rows.map(\.id)
            self.chrome.quickOpen.display(
                results: rows.map {
                    QuickOpenResult(path: $0.title, subtitle: $0.subtitle, positions: $0.positions)
                },
                totalCount: rows.count)
        }
    }

    private func paletteRowOpened(_ row: Int) {
        guard let session = paletteSession,
            row >= 0, row < session.rowIDs.count
        else { return }
        // Fire-and-forget: select_cb's return value is irrelevant. The
        // panel closes right after (openSelection → close → close_cb).
        controller.dispatchUICallbackDetached(
            session.selectCb, payload: [(.string("id"), session.rowIDs[row])])
    }

    private func paletteSessionClosed() {
        guard let session = paletteSession else { return }
        paletteSession = nil
        if let closeCb = session.closeCb {
            controller.dispatchUICallbackDetached(closeCb, payload: [])
        }
        // Restore the built-in ⌘P wiring exactly as it was.
        let quickOpen = chrome.quickOpen
        quickOpen.onQueryChange = session.savedOnQueryChange
        quickOpen.onOpen = session.savedOnOpen
        quickOpen.onOpenIndex = session.savedOnOpenIndex
        quickOpen.onClose = session.savedOnClose
        quickOpen.placeholder = session.savedPlaceholder
        chrome.restoreFocus?()
    }

    /// query_cb reply → typed rows. `[{id, title, subtitle?, positions?}]`;
    /// positions arrive 1-based (Lua) and convert to the 0-based indices
    /// QuickOpenResult expects; rows without a title are skipped.
    static func decodePaletteRows(
        _ value: Value?
    ) -> [(id: Value, title: String, subtitle: String?, positions: [Int])]? {
        guard let rows = value?.arrayValue else { return nil }
        return rows.compactMap { row in
            guard let title = row["title"]?.stringValue else { return nil }
            let positions = (row["positions"]?.arrayValue ?? [])
                .compactMap { $0.intValue.map { $0 - 1 } }
                .filter { $0 >= 0 }
            return (
                id: row["id"] ?? .nil,
                title: title,
                subtitle: row["subtitle"]?.stringValue,
                positions: positions
            )
        }
    }

    // MARK: - Input prompts

    /// `input open {prompt?, default?, submit_cb}` → native NSAlert with an
    /// accessory text field. Enter → submit_cb({text}); Esc/Cancel →
    /// submit_cb({}) with text omitted (the Lua side passes vim.NIL).
    private func openInput(_ args: Value) {
        guard let submitCb = args["submit_cb"]?.intValue else {
            return logMalformed("input", "open")
        }
        guard let window = chrome.attachedWindow else {
            // Headless / no window: resolve the callback as cancelled so the
            // Lua side never leaks a registered callback.
            controller.dispatchUICallbackDetached(submitCb, payload: [])
            return
        }
        let alert = NSAlert()
        alert.messageText = args["prompt"]?.stringValue ?? "Input"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = args["default"]?.stringValue ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")  // Return
        alert.addButton(withTitle: "Cancel")  // Esc (NSAlert binds it)
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                self.controller.dispatchUICallbackDetached(
                    submitCb, payload: [(.string("text"), .string(field.stringValue))])
            } else {
                self.controller.dispatchUICallbackDetached(submitCb, payload: [])
            }
            self.chrome.restoreFocus?()
        }
    }

    // MARK: - Helpers

    private func parseColor(_ value: Value?) -> NSColor? {
        guard let string = value?.stringValue else { return nil }
        guard let color = UIColorHex.parse(string) else {
            logger.error("superlemon.ui: unparseable color \(string, privacy: .public)")
            return nil
        }
        return color
    }

    private func logMalformed(_ component: String, _ method: String) {
        logger.error(
            "superlemon.ui: malformed args for \(component, privacy: .public).\(method, privacy: .public)"
        )
    }
}
