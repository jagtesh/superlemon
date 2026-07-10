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
    var surface: GridSurfaceView?
    /// Wave-3 chrome (ChromeKit + ShellKit); nil in smoke mode.
    var chrome: WorkspaceChrome?

    /// UserDefaults key for the App-menu "Use Superlemon Config" switch.
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

    private var terminationPending = false
    private var quitRequestInFlight = false

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
            // "Use Superlemon Config": skip the user's init in favor of the
            // managed, native-first config (App menu; takes effect at launch).
            if UserDefaults.standard.bool(forKey: Self.managedConfigDefaultsKey),
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
            try await session.attachUI(
                width: grid.cols, height: grid.rows,
                options: [
                    "ext_linegrid": .bool(true),
                    "ext_multigrid": .bool(true),
                    "rgb": .bool(true),
                ])
            attached = true
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
                            + "require('superlemon').setup(chan)"),
                    .array([.string(runtime.path), .int(Int64(channelID))]),
                ])
        } catch {
            NSLog("superlemon: runtime plugin bootstrap failed: \(error)")
        }
    }

    /// The runtime/ directory: env override → repo-relative to the executable
    /// (dev builds run from .build/<config>/) → cwd.
    private nonisolated static func runtimeDirectory() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["SUPERLEMON_RUNTIME"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
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

    /// Binary discovery per DESIGN §3: login-shell PATH (GUI apps don't
    /// inherit shell PATH), then the Homebrew location as fallback.
    private nonisolated static func resolveNvimBinary() async -> URL {
        await Task.detached(priority: .userInitiated) { () -> URL in
            if let path = loginShellNvimPath(),
                FileManager.default.isExecutableFile(atPath: path)
            {
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
                // Chrome sees the same batch before flush is acted on, so
                // grid and chrome present one consistent frame (WIRING.md §1).
                self.chrome?.apply(batch)
                if let flush = self.store.apply(batch) {
                    self.handleFlush(flush)
                }
            }
        }
    }

    /// superlemon.* rpcnotify traffic from the runtime plugin → chrome.
    private func consumeNotifications(from session: NvimSession) {
        notificationTask = Task { [weak self] in
            for await notification in session.notifications {
                guard let self else { return }
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
                    spec = FontSpec(name: candidate.name, size: size, linespace: linespace)
                    break
                }
            }
        }
        guard spec != surface.fontSpec else { return }
        surface.setFont(spec)
        sendResizeIfNeeded(force: true)
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

    /// Backs `applicationShouldTerminate`: nvim decides via `:confirm qa`;
    /// actual termination happens only on the lifecycle exit event.
    func handleTerminationRequest() -> NSApplication.TerminateReply {
        if sessionExited || session == nil { return .terminateNow }
        terminationPending = true
        requestQuit()
        return .terminateLater
    }

    /// Ask nvim to quit with `:confirm qa` semantics. Any command error
    /// (e.g. the user cancels the unsaved-changes prompt) cancels the quit.
    func requestQuit() {
        guard let session, !sessionExited, !quitRequestInFlight else { return }
        quitRequestInFlight = true
        Task { [weak self] in
            do {
                _ = try await session.request("nvim_command", [.string("confirm qa")])
                // On success nvim is exiting; the lifecycle event finishes the job.
            } catch {
                if let nvimError = error as? NvimError,
                    case .sessionTerminated = nvimError
                {
                    // nvim died mid-request because it quit — expected.
                } else {
                    self?.cancelQuit()
                }
            }
            self?.quitRequestInFlight = false
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
        guard attached, let session, let surface else { return }
        let size = surface.gridSize
        guard size.rows > 0, size.cols > 0 else { return }
        guard force || size != lastSentGridSize else { return }
        lastSentGridSize = size
        Task {
            await session.notify(
                "nvim_ui_try_resize",
                [.int(Int64(size.cols)), .int(Int64(size.rows))])
        }
    }

    // MARK: - Input plumbing (used by InputHostView / menu actions)

    var isMouseEnabled: Bool { store.isMouseEnabled }

    /// Fire-and-forget `nvim_input` (already in nvim key notation / escaped).
    func sendInput(_ keys: String) {
        guard let session else { return }
        Task { await session.notify("nvim_input", [.string(keys)]) }
    }

    /// Fire-and-forget `nvim_input_mouse`.
    func sendMouse(button: String, action: String, modifier: String, grid: Int, row: Int, col: Int) {
        guard let session else { return }
        Task {
            await session.notify(
                "nvim_input_mouse",
                [
                    .string(button), .string(action), .string(modifier),
                    .int(Int64(grid)), .int(Int64(row)), .int(Int64(col)),
                ])
        }
    }

    /// ⌘= / ⌘- / ⌘0 via superlemon.font: bump the guifont size or reset.
    func bumpFont(delta: Int) {
        guard let surface else { return }
        var spec = surface.fontSpec
        spec.size = delta == 0 ? 13 : max(6, min(72, spec.size + CGFloat(delta)))
        guard spec != surface.fontSpec else { return }
        surface.setFont(spec)
        sendResizeIfNeeded(force: true)
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
        guard let session else { return }
        Task {
            _ = try? await session.request(
                "nvim_exec_lua",
                [
                    .string("require('superlemon').chrome_toggle(...)"),
                    .array([.string(part)]),
                ])
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

    /// ⌘V: `nvim_paste` of the pasteboard string, single phase (-1).
    func pasteFromPasteboard() {
        guard let session,
            let text = NSPasteboard.general.string(forType: .string),
            !text.isEmpty
        else { return }
        Task {
            _ = try? await session.request(
                "nvim_paste", [.string(text), .bool(true), .int(-1)])
        }
    }
}
