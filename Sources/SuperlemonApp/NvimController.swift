// NvimController — owns the embedded nvim session, the grid model, and their
// wiring to the window/surface (DESIGN.md §2, §3, §10).

import AppKit
import GridKit
import NvimKit
import SurfaceKit

/// Everything here is main-actor: the two consumption Tasks are spawned from
/// main-actor context and therefore inherit it, so redraw batches hop from the
/// NvimKit actor straight onto main — GridStore application and surface
/// presentation need no further synchronization.
@MainActor
final class NvimController {
    let store = GridStore()

    private(set) var session: NvimSession?
    weak var window: NSWindow?
    var surface: GridSurfaceView? {
        didSet {
            oldValue?.onGridAccessorySizeRequest = nil
            oldValue?.onGridAccessoryViewportTargetRequest = nil
            configureEditorAccessoryBridge()
        }
    }
    /// Native ChromeKit + ShellKit workspace UI; nil in smoke mode.
    var chrome: WorkspaceChrome?

    /// UserDefaults key for the Settings managed-versus-user init choice.
    static let managedConfigDefaultsKey = "UseSuperlemonManagedConfig"

    /// Attach size used when there is no surface (headless `--smoke`).
    var headlessGridSize: (rows: Int, cols: Int) = (40, 120)

    /// Called once, on the first flushed frame (smoke-mode hook).
    var onFirstFlush: ((FlushResult) -> Void)?
    /// Overrides default exit handling (close window / alert / terminate).
    var exitHandler: ((Int32, String) -> Void)?
    /// Overrides default startup-failure handling (alert + terminate).
    var startupFailureHandler: ((String) -> Void)?

    private(set) var sessionExited = false

    private var uiTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private(set) var channelID: Int?

    private var attached = false
    private var lastSentGridSize: (rows: Int, cols: Int) = (0, 0)
    private var resizeScheduled = false

    private var firstFlushDelivered = false
    private var lastTitle: String?
    private var lastGuifont: String?
    private var lastLinespace: CGFloat = 0
    private var lastBackground: NvimKit.RGBColor?

    /// Rendering preferences originate in superlemon.vim and arrive through
    /// the runtime's `superlemon.settings` notification. Defaults match a
    /// pristine FontSpec so the first grid can render before bootstrap.
    private struct RenderingSettings: Equatable {
        var powerlineGlyphs = false
        var ligatures = true
        var useSymbolFont = false
        var forceGlyphFallback = false
        var minimapWidth: CGFloat = 88
        var minimapScale: CGFloat = 0.20
        var minimapPitch: CGFloat = 3.0
        var minimapMinEditorColumns = 40

        init() {}

        init(payload: Value) {
            powerlineGlyphs = payload["powerline_glyphs"]?.boolValue ?? false
            ligatures = payload["ligatures"]?.boolValue ?? true
            useSymbolFont = payload["use_symbol_font"]?.boolValue ?? false
            forceGlyphFallback = payload["force_glyph_fallback"]?.boolValue ?? false
            minimapWidth = max(
                48, min(160, CGFloat(payload["minimap_width"]?.doubleValue ?? 88)))
            minimapScale = max(
                0.10, min(0.50, CGFloat(payload["minimap_scale"]?.doubleValue ?? 0.20)))
            minimapPitch = max(
                1, min(6, CGFloat(payload["minimap_pitch"]?.doubleValue ?? 3.0)))
            minimapMinEditorColumns = max(
                20, min(120, payload["minimap_min_editor_columns"]?.intValue ?? 40))
        }

        func apply(to spec: inout FontSpec) {
            spec.powerlineGlyphs = powerlineGlyphs
            spec.ligatures = ligatures
            spec.useSymbolFont = useSymbolFont
            spec.forceSynthesis = forceGlyphFallback
        }
    }

    private var renderingSettings = RenderingSettings()
    private var nativeMinimapEnabled = true
    private var nativeScrollbarsEnabled = false
    private var minimapBridge: MinimapBridge!
    /// Font name/size/spacing derived only from Neovim's guifont/linespace.
    /// Command-0 returns to this value after temporary native zooming.
    private var configuredFontSpec = FontSpec()

    private var terminationPending = false
    private var quitRequestInFlight = false

    /// Keyboard, mouse, paste, and resize traffic share one main-actor queue.
    /// A single drain preserves call order and batches adjacent notifications
    /// into serialized pipe writes without pacing input.
    private var pendingInputCommands: [NvimInputCommand] = []
    private var inputDrainTask: Task<Void, Never>?
    private var inputReady = false

    init() {
        minimapBridge = MinimapBridge(
            surface: nil,
            notify: { [weak self] method, params in
                guard let session = self?.session else { return }
                Task { await session.notify(method, params) }
            })
    }

    // MARK: - Startup

    /// Spawn nvim, handshake, attach the UI, and start the consumption loops.
    func start() async {
        do {
            let binary = await Self.resolveNvimBinary()
            // Debug facility: SUPERLEMON_LISTEN=<path> exposes the embedded
            // nvim on a socket so it can be driven with `nvim --server`.
            var arguments = ["--embed"]
            if let listen = ProcessInfo.processInfo.environment["SUPERLEMON_LISTEN"],
                !listen.isEmpty
            {
                arguments += ["--listen", listen]
            }
            // Config source (Settings), in priority order:
            // 1. an explicit custom init path, 2. the managed native-first
            // config (the default), 3. the user's own init (no -u at all).
            let defaults = UserDefaults.standard
            if let custom = defaults.string(forKey: "CustomInitPath"),
                !custom.isEmpty, FileManager.default.fileExists(atPath: custom)
            {
                arguments += ["-u", custom]
            } else if defaults.bool(forKey: Self.managedConfigDefaultsKey),
                let managed = Self.runtimeDirectory()?
                    .appendingPathComponent("config/init.lua"),
                FileManager.default.fileExists(atPath: managed.path)
            {
                arguments += ["-u", managed.path]
            }
            let configuration = NvimLaunchConfiguration(
                binaryURL: binary,
                arguments: arguments,
                workingDirectory: Self.workingDirectory(),
                environment: ProcessInfo.processInfo.environment
            )
            let session = NvimSession(configuration: configuration)
            self.session = session

            // Start consuming before any bytes flow so nothing is dropped.
            consumeUIEvents(from: session)
            consumeLifecycleEvents(from: session)
            consumeNotifications(from: session)
            // Clipboard provider handlers must be in place before any bytes
            // flow — the runtime plugin registers g:clipboard at setup.
            await session.setRequestHandler(Self.makeRequestHandler())

            try await session.start()
            let info = try await session.handshake()
            channelID = info.channelID

            let grid = surface?.gridSize ?? headlessGridSize
            lastSentGridSize = grid
            // M2: multigrid on — every nvim window is its own CALayer
            // (SurfaceKit resolves frames/z-order via GridLayout).
            // M3: full externalization — ChromeKit renders the cmdline (:),
            // completion/wildmenu dropdowns, and messages natively.
            try await session.attachUI(
                width: grid.cols, height: grid.rows,
                options: [
                    "ext_linegrid": .bool(true),
                    "ext_multigrid": .bool(true),
                    "ext_cmdline": .bool(true),
                    "ext_popupmenu": .bool(true),
                    "ext_messages": .bool(true),
                    "rgb": .bool(true),
                ])
            attached = true
            inputReady = true
            scheduleInputDrainIfNeeded()
            // The view may have been laid out while attaching.
            sendResizeIfNeeded()
            await bootstrapRuntimePlugin(session)
        } catch {
            handleStartupFailure(error)
        }
    }

    /// Load the bundled superlemon.nvim plugin (DESIGN §9, runtime/CONTRACT.md):
    /// prepend the runtime dir to rtp, then setup(channel). Non-fatal on error
    /// — the editor still works without status/clipboard/⌘-keymaps.
    private func bootstrapRuntimePlugin(_ session: NvimSession) async {
        guard let channelID, let runtime = Self.runtimeDirectory() else { return }
        do {
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string(
                        "local path, chan = ...\n"
                            + "vim.opt.runtimepath:prepend(path)\n"
                            + "require('superlemon.settings').source_user_config()\n"
                            + "require('superlemon').setup(chan)"),
                    .array([.string(runtime.path), .int(Int64(channelID))]),
                ])
        } catch {
            NSLog("superlemon: runtime plugin bootstrap failed: \(error)")
        }
    }

    /// Apply the renderer half of superlemon.vim. Neovim remains authoritative
    /// for font name/size/spacing through guifont and linespace.
    func applyRuntimeSettings(_ payload: Value) {
        renderingSettings = RenderingSettings(payload: payload)
        var spec = configuredFontSpec
        renderingSettings.apply(to: &spec)
        applyFontSpec(spec)
        applyEditorAccessorySettings()
    }

    /// Live View-menu/config state. SurfaceKit owns the concrete accessory
    /// presentation; keeping the state here also covers notifications that
    /// arrive before the window surface is attached.
    func setEditorAccessories(minimap: Bool, scrollbars: Bool) {
        nativeMinimapEnabled = minimap
        nativeScrollbarsEnabled = scrollbars
        applyEditorAccessorySettings()
    }

    private func applyEditorAccessorySettings() {
        guard let surface else { return }
        surface.showsMinimap = nativeMinimapEnabled
        surface.showsNativeScrollbars = nativeScrollbarsEnabled
        surface.minimapWidth = renderingSettings.minimapWidth
        surface.minimapScale = renderingSettings.minimapScale
        surface.minimapPitch = renderingSettings.minimapPitch
        surface.minimapMinEditorColumns = renderingSettings.minimapMinEditorColumns
    }

    private func configureEditorAccessoryBridge() {
        minimapBridge.attach(to: surface)
        guard let surface else { return }
        surface.onGridAccessorySizeRequest = { [weak self] request in
            self?.enqueueInput(
                .resizeGrid(
                    grid: request.gridID, cols: request.cols, rows: request.rows))
        }
        surface.onGridAccessoryViewportTargetRequest = { [weak self] request in
            guard let buffer = request.bufferHandle else { return }
            self?.enqueueInput(
                .viewportTarget(
                    grid: request.gridID,
                    window: request.windowHandle,
                    buffer: buffer,
                    topline: request.targetTopline,
                    activate: request.phase == .began))
        }
        applyEditorAccessorySettings()
    }

    /// The runtime/ directory: env override → repo-relative to the executable
    /// (dev builds run from .build/<config>/) → cwd.
    nonisolated static func runtimeDirectory() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["SUPERLEMON_RUNTIME"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("runtime", isDirectory: true))
        }
        let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        candidates.append(
            executable.deletingLastPathComponent()  // .build/debug
                .deletingLastPathComponent()  // .build
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("runtime", isDirectory: true))
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("runtime", isDirectory: true))
        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("lua/superlemon/init.lua").path)
        }
    }

    /// Binary discovery per DESIGN §3, in order:
    /// 1. SUPERLEMON_NVIM env override
    /// 2. a bundled copy (Contents/Helpers/nvim in an .app, or next to the
    ///    executable in dev builds) — the packaging step drops it in here
    /// 3. login-shell PATH (GUI apps don't inherit shell PATH)
    /// 4. the Homebrew location as a last resort
    private nonisolated static func resolveNvimBinary() async -> URL {
        await Task.detached(priority: .userInitiated) { () -> URL in
            let fm = FileManager.default
            if let env = ProcessInfo.processInfo.environment["SUPERLEMON_NVIM"],
                fm.isExecutableFile(atPath: env)
            {
                return URL(fileURLWithPath: env)
            }
            let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
            let bundled = [
                executable.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Helpers/nvim"),  // .app layout
                executable.deletingLastPathComponent()
                    .appendingPathComponent("nvim"),  // dev layout
            ]
            if let found = bundled.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
                return found
            }
            if let path = loginShellNvimPath(), fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return URL(fileURLWithPath: "/opt/homebrew/bin/nvim")
        }.value
    }

    private nonisolated static func loginShellNvimPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v nvim"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Login shells may print banners; the path is the last line.
        guard let path = output.split(separator: "\n").last.map(String.init),
            !path.isEmpty
        else { return nil }
        return path
    }

    nonisolated static func workingDirectory() -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        // Apps launched from Finder start at "/"; use the home directory then.
        if cwd == "/" || cwd.isEmpty {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
    }

    private func handleStartupFailure(_ error: Error) {
        sessionExited = true  // lets the quit flow terminate immediately
        resetInputQueue()
        let message = String(describing: error)
        if let startupFailureHandler {
            startupFailureHandler(message)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not start Neovim"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Consumption loop: redraw events

    private func consumeUIEvents(from session: NvimSession) {
        uiTask = Task { [weak self] in
            for await batch in session.uiEvents {
                guard let self else { return }
                // Chrome consumes every batch in wire order. Compatible grid
                // scroll frames may coalesce to the next display opportunity,
                // but the authoritative model never drops an event.
                self.chrome?.apply(batch)
                switch self.store.applyDeferred(batch) {
                case .none:
                    break
                case .immediate:
                    self.drainPendingPresentation()
                case .displayLinked:
                    let scheduled = self.surface?.schedulePresentationOnNextDisplay {
                        [weak self] in self?.drainPendingPresentation()
                    } ?? false
                    if !scheduled { self.drainPendingPresentation() }
                }
            }
        }
    }

    private func drainPendingPresentation() {
        guard let flush = store.consumePendingPresentation() else { return }
        handleFlush(flush)
    }

    /// superlemon.* rpcnotify traffic from the runtime plugin → chrome.
    private func consumeNotifications(from session: NvimSession) {
        notificationTask = Task { [weak self] in
            for await notification in session.notifications {
                guard let self else { return }
                if self.minimapBridge.handleNotification(
                    notification.method, params: notification.params)
                {
                    continue
                }
                self.chrome?.handleNotification(notification.method, notification.params)
            }
        }
    }

    /// Clipboard provider backing (runtime/CONTRACT.md): the plugin's
    /// g:clipboard rpcrequests both ways. Linewise contents keep their
    /// trailing "" element — nvim's own convention; we translate faithfully.
    private nonisolated static func makeRequestHandler()
        -> @Sendable (String, [Value]) async -> Result<Value, NvimHandlerError>
    {
        { method, params in
            switch method {
            case "superlemon.clipboard_get":
                let text = await MainActor.run {
                    NSPasteboard.general.string(forType: .string) ?? ""
                }
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { Value.string(String($0)) }
                let regtype = text.hasSuffix("\n") ? "V" : "v"
                return .success(.array([.array(lines), .string(regtype)]))

            case "superlemon.clipboard_set":
                guard let lines = params.first?.arrayValue else {
                    return .failure("clipboard_set: missing lines")
                }
                let text = lines.compactMap(\.stringValue).joined(separator: "\n")
                await MainActor.run {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                return .success(.nil)

            default:
                return .failure("superlemon: no handler for method '\(method)'")
            }
        }
    }

    private func handleFlush(_ flush: FlushResult) {
        surface?.present(flush)

        if flush.title != lastTitle {
            lastTitle = flush.title
            window?.title = flush.title.isEmpty ? "Superlemon" : flush.title
        }
        applyWindowBackground(flush.highlights.defaultBackground)
        applyGuifontIfChanged()

        if !firstFlushDelivered {
            firstFlushDelivered = true
            onFirstFlush?(flush)
        }
    }

    /// Keep the window's own background in sync with nvim's default background
    /// so live-resize gaps match, and hint the appearance from its luminance.
    private func applyWindowBackground(_ background: NvimKit.RGBColor) {
        guard background != lastBackground else { return }
        lastBackground = background
        guard let window else { return }
        let red = CGFloat((background.rgb >> 16) & 0xFF) / 255
        let green = CGFloat((background.rgb >> 8) & 0xFF) / 255
        let blue = CGFloat(background.rgb & 0xFF) / 255
        window.backgroundColor = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        window.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
    }

    /// `option_set guifont`/`linespace` → FontSpec → surface.setFont, followed
    /// by a (forced) resize so nvim relayouts to the new cell geometry.
    private func applyGuifontIfChanged() {
        guard let surface else { return }
        let guifont = store.options["guifont"]?.stringValue
        let linespace = CGFloat(store.options["linespace"]?.intValue ?? 0)
        guard guifont != lastGuifont || linespace != lastLinespace else { return }
        lastGuifont = guifont
        lastLinespace = linespace

        var spec = FontSpec(name: nil, size: 13, linespace: linespace)
        if let guifont, !guifont.isEmpty {
            for candidate in GuifontParser.candidates(from: guifont) {
                let size = CGFloat(candidate.size ?? Double(surface.fontSpec.size))
                if NSFont(name: candidate.name, size: size) != nil {
                    spec.name = candidate.name
                    spec.size = size
                    break
                }
            }
        }
        configuredFontSpec = spec
        renderingSettings.apply(to: &spec)
        applyFontSpec(spec)
    }

    /// Install one fully resolved font spec and keep the native statusline's
    /// Powerline synthesis policy in lockstep with the grid renderer.
    private func applyFontSpec(_ spec: FontSpec) {
        guard let surface else { return }
        chrome?.statusBar.synthesizePowerline =
            spec.powerlineGlyphs && (spec.useSymbolFont || spec.forceSynthesis)
        guard spec != surface.fontSpec else { return }
        let metricsChanged =
            spec.size != surface.fontSpec.size || spec.name != surface.fontSpec.name
                || spec.linespace != surface.fontSpec.linespace
        surface.setFont(spec)
        if metricsChanged { sendResizeIfNeeded(force: true) }
    }

    // MARK: - Consumption loop: lifecycle

    private func consumeLifecycleEvents(from session: NvimSession) {
        lifecycleTask = Task { [weak self] in
            for await event in session.lifecycleEvents {
                guard let self else { return }
                switch event {
                case .exited(let exitCode, let stderrTail):
                    self.handleSessionExit(code: exitCode, stderrTail: stderrTail)
                }
            }
        }
    }

    private func handleSessionExit(code: Int32, stderrTail: String) {
        sessionExited = true
        resetInputQueue()
        if let exitHandler {
            exitHandler(code, stderrTail)
            return
        }
        if code != 0 {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Neovim exited unexpectedly (code \(code))"
            alert.informativeText =
                stderrTail.isEmpty
                ? "No stderr output was captured."
                : String(stderrTail.suffix(2000))
            alert.addButton(withTitle: "Quit")
            alert.runModal()
        }
        window?.close()
        if terminationPending {
            terminationPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        } else {
            NSApp.terminate(nil)  // sessionExited → applicationShouldTerminate says .terminateNow
        }
    }

    // MARK: - Quit flow (DESIGN §3)

    /// Backs `applicationShouldTerminate`: the app owns the native modified-
    /// buffer choice, while actual termination waits for nvim's lifecycle exit.
    func handleTerminationRequest() -> NSApplication.TerminateReply {
        if sessionExited || session == nil { return .terminateNow }
        terminationPending = true
        requestQuit()
        return .terminateLater
    }

    /// Quit without ever blocking on nvim (a blocking `:confirm qa` request
    /// wedged termination: AppKit ignores further ⌘Q while a .terminateLater
    /// reply is pending, so a missed in-grid prompt looked like a lockup and
    /// grayed the Quit item). Instead: query modified buffers with a hang
    /// timeout, then drive a NATIVE save/discard/cancel dialog; every path
    /// resolves the pending termination reply.
    func requestQuit() {
        guard let session, !sessionExited, !quitRequestInFlight else { return }
        quitRequestInFlight = true
        Task { [weak self] in
            await self?.runQuitFlow(session)
            self?.quitRequestInFlight = false
        }
    }

    private func runQuitFlow(_ session: NvimSession) async {
        // 1. What would be lost? (2s guard: nvim may itself be stuck at a
        //    blocking prompt — swapfile dialog, hit-enter — and never answer.)
        let modified = await Self.withTimeout(seconds: 2) {
            () -> [String]? in
            let lua = """
                local names = {}
                for _, b in ipairs(vim.api.nvim_list_bufs()) do
                  if vim.bo[b].buflisted and vim.bo[b].modified then
                    local n = vim.api.nvim_buf_get_name(b)
                    names[#names + 1] = n ~= "" and vim.fn.fnamemodify(n, ":t") or "[No Name]"
                  end
                end
                return names
                """
            let reply = try? await session.request("nvim_exec_lua", [.string(lua), .array([])])
            return reply?.arrayValue?.compactMap(\.stringValue) ?? []
        }

        guard let modified else {
            presentUnresponsiveAlert(session)
            return
        }
        if modified.isEmpty {
            // Nothing to lose; qa! cannot prompt. Lifecycle exit finishes it.
            _ = try? await session.request("nvim_command", [.string("qa!")])
            return
        }
        presentUnsavedAlert(modified, session: session)
    }

    /// Native Save All / Discard All / Cancel — replaces nvim's in-grid
    /// y/n/c confirm prompt for the quit path.
    private func presentUnsavedAlert(_ names: [String], session: NvimSession) {
        guard let window else {
            cancelQuit()  // headless: never discard silently
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            names.count == 1
            ? "“\(names[0])” has unsaved changes"
            : "\(names.count) buffers have unsaved changes"
        let shown = names.prefix(6).joined(separator: "\n")
        alert.informativeText =
            names.count > 6 ? shown + "\n… and \(names.count - 6) more" : shown
        alert.addButton(withTitle: "Save All & Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard All & Quit")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:  // Save All & Quit
                Task {
                    do {
                        _ = try await session.request("nvim_command", [.string("wall")])
                        _ = try await session.request("nvim_command", [.string("qa!")])
                    } catch {
                        // E.g. E141: a buffer has no file name. Stay open.
                        self.cancelQuit()
                        self.presentInfoAlert(
                            "Couldn’t save all buffers",
                            detail:
                                "Some buffers could not be written (unnamed buffer?). "
                                + "Save them in the editor, then quit again.")
                    }
                }
            case .alertThirdButtonReturn:  // Discard All & Quit
                Task { _ = try? await session.request("nvim_command", [.string("qa!")]) }
            default:  // Cancel
                self.cancelQuit()
            }
        }
    }

    /// nvim didn't answer within the guard window (stuck at a blocking
    /// prompt or hung): offer a way out that always resolves.
    private func presentUnresponsiveAlert(_ session: NvimSession) {
        guard let window else {
            cancelQuit()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Neovim is not responding"
        alert.informativeText =
            "It may be waiting at a prompt inside the editor. "
            + "You can force quit (unsaved changes will be lost) or cancel and check the editor."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Force Quit")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertSecondButtonReturn {
                Task { await session.terminate() }  // exit → lifecycle → reply
            } else {
                self.cancelQuit()
            }
        }
    }

    private func presentInfoAlert(_ message: String, detail: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }

    /// First result wins: the operation, or nil at the deadline.
    private static func withTimeout<T: Sendable>(
        seconds: Double, _ operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func cancelQuit() {
        guard terminationPending else { return }
        terminationPending = false
        NSApp.reply(toApplicationShouldTerminate: false)
    }

    // MARK: - Resize

    /// Called from the host view's `layout()`. Coalesces to one
    /// `nvim_ui_try_resize` per runloop tick during live resize.
    func surfaceLayoutChanged() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.sendResizeIfNeeded()
        }
    }

    private func sendResizeIfNeeded(force: Bool = false) {
        guard attached, let surface else { return }
        let size = surface.gridSize
        guard size.rows > 0, size.cols > 0 else { return }
        guard force || size != lastSentGridSize else { return }
        lastSentGridSize = size
        enqueueInput(.resize(cols: size.cols, rows: size.rows))
    }

    // MARK: - Input plumbing (used by InputHostView / menu actions)

    var isMouseEnabled: Bool { store.isMouseEnabled }

    /// Fire-and-forget `nvim_input` (already in nvim key notation / escaped).
    func sendInput(_ keys: String) {
        enqueueInput(.keys(keys))
    }

    /// Fire-and-forget `nvim_input_mouse`.
    func sendMouse(
        button: String, action: String, modifier: String,
        grid: Int, row: Int, col: Int, repeatCount: Int = 1
    ) {
        guard repeatCount > 0 else { return }
        enqueueInput(
            .mouse(
                button: button, action: action, modifier: modifier,
                grid: grid, row: row, col: col, repeatCount: repeatCount))
    }

    private func enqueueInput(_ command: NvimInputCommand) {
        guard !sessionExited else { return }
        if let last = pendingInputCommands.last,
            let merged = last.coalesced(with: command)
        {
            pendingInputCommands[pendingInputCommands.count - 1] = merged
        } else {
            pendingInputCommands.append(command)
        }
        scheduleInputDrainIfNeeded()
    }

    private func scheduleInputDrainIfNeeded() {
        guard inputReady, session != nil, !pendingInputCommands.isEmpty,
            inputDrainTask == nil
        else { return }
        inputDrainTask = Task { [weak self] in
            await self?.drainInputQueue()
        }
    }

    private func drainInputQueue() async {
        defer { inputDrainTask = nil }

        while !Task.isCancelled, inputReady, let session,
            !pendingInputCommands.isEmpty
        {
            let commands = pendingInputCommands
            pendingInputCommands.removeAll(keepingCapacity: true)
            var notifications: [NvimSession.OutgoingNotification] = []
            for command in commands {
                if case .paste(let text) = command {
                    if !notifications.isEmpty {
                        await session.notifyBatch(notifications)
                        notifications.removeAll(keepingCapacity: true)
                    }
                    _ = try? await session.request(
                        "nvim_paste", [.string(text), .bool(true), .int(-1)])
                } else {
                    notifications.append(contentsOf: command.notifications)
                }
            }
            if !notifications.isEmpty { await session.notifyBatch(notifications) }
        }
    }

    private func resetInputQueue() {
        inputReady = false
        inputDrainTask?.cancel()
        inputDrainTask = nil
        pendingInputCommands.removeAll(keepingCapacity: false)
    }

    /// ⌘= / ⌘- / ⌘0 via superlemon.font: temporary native zoom. Reset returns
    /// to the guifont/linespace values from the active Neovim configuration.
    func bumpFont(delta: Int) {
        guard let surface else { return }
        var spec = delta == 0 ? configuredFontSpec : surface.fontSpec
        renderingSettings.apply(to: &spec)
        if delta != 0 {
            spec.size = max(6, min(72, spec.size + CGFloat(delta)))
        }
        applyFontSpec(spec)
    }

    /// Native tab strip: switch to a buffer (CONTRACT.md superlemon.buffers).
    func switchToBuffer(_ bufnr: Int) {
        guard let session else { return }
        Task {
            _ = try? await session.request(
                "nvim_set_current_buf", [.int(Int64(bufnr))])
        }
    }

    /// Native tab strip: close a buffer, letting nvim confirm unsaved edits.
    func closeBuffer(_ bufnr: Int) {
        guard let session else { return }
        Task {
            _ = try? await session.request(
                "nvim_command", [.string("confirm bdelete \(bufnr)")])
        }
    }

    /// View menu → plugin truth: toggle native chrome (CONTRACT.md).
    func toggleNativeChrome(_ part: String) {
        guard let session else {
            NSLog("superlemon: toggleNativeChrome(\(part)) — no session")
            return
        }
        Task {
            do {
                _ = try await session.request(
                    "nvim_exec_lua",
                    [
                        .string("require('superlemon').chrome_toggle(...)"),
                        .array([.string(part)]),
                    ])
            } catch {
                // Most likely: the runtime plugin failed to bootstrap.
                NSLog("superlemon: toggleNativeChrome(\(part)) failed: \(error)")
            }
        }
    }

    /// Open a file through nvim (`:drop` keeps buffer state coherent,
    /// DESIGN §14.1); fnameescape guards spaces/specials.
    func openFile(_ absolutePath: String) {
        guard let session else { return }
        Task {
            _ = try? await session.request(
                "nvim_exec_lua",
                [
                    .string("vim.cmd.drop(vim.fn.fnameescape(...))"),
                    .array([.string(absolutePath)]),
                ])
        }
    }

    /// Change Neovim's global working directory, then re-root the native
    /// sidebar and quick-open index to the same folder. Neovim performs the
    /// change so `DirChanged` autocmds and user configuration still run.
    func openFolder(_ absolutePath: String) {
        guard let session else { return }
        let root = URL(fileURLWithPath: absolutePath, isDirectory: true).standardizedFileURL
        Task {
            do {
                let currentDirectory = try await session.request(
                    "nvim_exec_lua",
                    [
                        .string(
                            "local path = ...\n"
                                + "vim.api.nvim_set_current_dir(path)\n"
                                + "return vim.fn.getcwd()"),
                        .array([.string(root.path)]),
                    ])
                // Use Neovim's canonical cwd (not the panel's possibly
                // symlinked URL) so relative native paths resolve identically.
                let authoritativeRoot = currentDirectory.stringValue
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? root
                chrome?.setProjectRoot(authoritativeRoot)
            } catch {
                presentInfoAlert(
                    "Couldn’t open folder",
                    detail: String(describing: error))
            }
        }
    }

    /// Absolute name of the current buffer, or nil for an unnamed/special
    /// buffer. Used only to seed the native Save As panel; Neovim remains
    /// responsible for writing and renaming the buffer.
    func currentBufferPath() async -> String? {
        guard let session else { return nil }
        guard
            let name = try? await session.request(
                "nvim_buf_get_name", [.int(0)]),
            let path = name.stringValue,
            !path.isEmpty,
            !path.contains("://")
        else { return nil }
        return path
    }

    /// Save the current buffer under a new name. NSSavePanel has already
    /// confirmed replacement, hence `bang = true`; routing the operation
    /// through `nvim_cmd` preserves encoding, autocmds, undo, and buffer state.
    func saveFile(as absolutePath: String) {
        guard let session else { return }
        Task {
            do {
                _ = try await session.request(
                    "nvim_exec_lua",
                    [
                        .string(
                            "vim.api.nvim_cmd({ cmd = 'saveas', args = { ... }, bang = true }, {})"
                        ),
                        .array([.string(absolutePath)]),
                    ])
            } catch {
                presentInfoAlert(
                    "Couldn’t save file",
                    detail: String(describing: error))
            }
        }
    }

    /// Create a durable user-owned settings file from the bundled annotated
    /// template on first use, then open it in Neovim. The managed init sources
    /// `$XDG_CONFIG_HOME/superlemon/init.vim` after the bundled baseline.
    func openSuperlemonConfig(templatePath: String) {
        guard let session else { return }
        Task {
            do {
                _ = try await session.request(
                    "nvim_exec_lua",
                    [
                        .string(
                            "local template = ...\n"
                                + "local target = require('superlemon.settings').ensure_user_config(template)\n"
                                + "vim.cmd.drop(vim.fn.fnameescape(target))\n"
                                + "return target"),
                        .array([.string(templatePath)]),
                    ])
            } catch {
                NSLog("superlemon: could not open user settings: \(error)")
            }
        }
    }

    /// Sidebar single-click: open as a PREVIEW buffer (VS Code/Sublime
    /// semantics — see superlemon.preview and CONTRACT.md).
    func previewFile(_ absolutePath: String) {
        guard let session else { return }
        Task {
            _ = try? await session.request(
                "nvim_exec_lua",
                [
                    .string("require('superlemon.preview').open(...)"),
                    .array([.string(absolutePath)]),
                ])
        }
    }

    /// Sidebar double-click: open pinned (promotes if currently previewed).
    func openFilePermanently(_ absolutePath: String) {
        guard let session else { return }
        Task {
            _ = try? await session.request(
                "nvim_exec_lua",
                [
                    .string("require('superlemon.preview').open_permanent(...)"),
                    .array([.string(absolutePath)]),
                ])
        }
    }

    /// Double-click (file or tab): pin the preview buffer permanently.
    func promoteBuffer(_ bufnr: Int) {
        guard let session else { return }
        Task {
            _ = try? await session.request(
                "nvim_exec_lua",
                [
                    .string("require('superlemon.preview').promote(...)"),
                    .array([.int(Int64(bufnr))]),
                ])
        }
    }

    /// superlemon.ui callback dispatch (runtime/CONTRACT.md): blocking
    /// request into the Lua-side callback registry. Returns the callback's
    /// return value, or nil on any error (freed id, Lua error, no session).
    func dispatchUICallback(_ id: Int, payload: [(Value, Value)]) async -> Value? {
        guard let session else { return nil }
        return try? await session.request(
            "nvim_exec_lua",
            [
                .string("return require('superlemon.ui')._dispatch(...)"),
                .array([.int(Int64(id)), .map(payload)]),
            ])
    }

    /// Fire-and-forget variant of `dispatchUICallback` for select/submit
    /// callbacks whose return value is irrelevant.
    func dispatchUICallbackDetached(_ id: Int, payload: [(Value, Value)]) {
        Task { _ = await self.dispatchUICallback(id, payload: payload) }
    }

    /// ⌘V: `nvim_paste` of the pasteboard string, single phase (-1).
    func pasteFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
            !text.isEmpty
        else { return }
        enqueueInput(.paste(text))
    }
}
