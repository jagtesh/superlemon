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
public final class NvimController {
    private struct SessionContext {
        let session: NvimSession
        let generation: Int
    }

    struct TerminationIntentStore {
        enum Intent {
            case quit
            case relaunch(() throws -> Void)
        }

        private var intent: Intent?

        var isPending: Bool { intent != nil }

        mutating func requestQuitIfNeeded() {
            if intent == nil { intent = .quit }
        }

        mutating func requestRelaunch(_ action: @escaping () throws -> Void) {
            intent = .relaunch(action)
        }

        @discardableResult
        mutating func cancel() -> Bool {
            let wasPending = intent != nil
            intent = nil
            return wasPending
        }

        mutating func take() -> Intent? {
            defer { intent = nil }
            return intent
        }
    }

    struct LifecycleState: Equatable, Sendable {
        enum Phase: String, Equatable, Sendable {
            case idle
            case starting
            case running
            case inspectingQuit
            case awaitingQuitChoice
            case saving
            case stopping
            case recovering
            case terminated
        }

        var phase: Phase = .idle
        var generation = 0

        @discardableResult
        mutating func beginGeneration() -> Int {
            generation += 1
            return generation
        }

        func accepts(generation candidate: Int) -> Bool {
            candidate == generation
        }
    }

    private typealias Phase = LifecycleState.Phase

    enum StartupError: LocalizedError {
        case runtimeMissing
        case nvimNotFound
        case unsupportedNvimVersion(String)
        case bridgeNotReady(String)
        case config(path: String?, message: String)

        var errorDescription: String? {
            switch self {
            case .runtimeMissing:
                "The bundled Superlemon runtime is missing. Reinstall Superlemon."
            case .nvimNotFound:
                "No usable Neovim executable was found. Packaged builds require the bundled copy."
            case .unsupportedNvimVersion(let version):
                "Superlemon requires Neovim 0.11 or newer; found \(version)."
            case .bridgeNotReady(let reason):
                "The Superlemon runtime bridge did not become ready: \(reason)"
            case .config(let path, let message):
                "The Neovim configuration\(path.map { " at \($0)" } ?? "") failed: \(message)"
            }
        }
    }

    let store = GridStore()

    private(set) var session: NvimSession?
    weak var window: NSWindow?
    weak var inputHost: InputHostView?
    var surface: GridSurfaceView? {
        didSet {
            oldValue?.onGridAccessorySizeRequest = nil
            oldValue?.onGridAccessoryViewportTargetRequest = nil
            configureEditorAccessoryBridge()
        }
    }
    /// Native ChromeKit + ShellKit workspace UI; nil in smoke mode.
    var chrome: WorkspaceChrome?

    /// Attach size used when there is no surface (headless `--smoke`).
    var headlessGridSize: (rows: Int, cols: Int) = (40, 120)

    /// Called once, on the first flushed frame (smoke-mode hook).
    public var onFirstFlush: ((FlushResult) -> Void)?
    /// Overrides default exit handling (close window / alert / terminate).
    public var exitHandler: ((Int32, String) -> Void)?
    /// Overrides default startup-failure handling (alert + terminate).
    public var startupFailureHandler: ((String) -> Void)?

    public private(set) var sessionExited = false
    private var lifecycle = LifecycleState()
    private var phase: Phase {
        get { lifecycle.phase }
        set { lifecycle.phase = newValue }
    }
    private var sessionGeneration: Int { lifecycle.generation }
    private var activeConfigMode: NvimConfigMode = .managed
    /// When set, `launchSession` uses this configuration verbatim instead of
    /// resolving a local binary and building a launch plan.
    private let customLaunchConfiguration: NvimLaunchConfiguration?
    /// True when the connected session's filesystem is not this machine's
    /// (host-supplied transports such as an ssh bridge). Native workspace
    /// chrome then sources the sidebar tree and quick-open index through the
    /// RPC channel (`superlemon.workspace`, runtime/CONTRACT.md) instead of
    /// the local filesystem, and the session's own cwd — not the host's —
    /// becomes the project root once startup completes.
    public let hasRemoteFilesystem: Bool
    private var activeConfigPath: String?
    private var safeStartRequested = false

    private var uiTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?
    private var stopRequested = false
    private(set) var channelID: Int?

    private let nvimBinaryResolver: @Sendable () async throws -> URL
    private let configSelectionProvider: @MainActor () -> NvimConfigSelection
    var requestApplicationTermination: @MainActor () -> Void = { NSApp.terminate(nil) }
    var replyToApplicationTermination: @MainActor (Bool) -> Void = {
        NSApp.reply(toApplicationShouldTerminate: $0)
    }

    private var attached = false
    private var lastSentGridSize: (rows: Int, cols: Int) = (0, 0)
    private var resizeScheduled = false

    private var firstFlushDelivered = false
    private var pendingFirstFlush: FlushResult?
    private var runtimeReady = false
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

    private var quitRequestInFlight = false
    /// A normal AppKit quit can arrive after the child exists but before
    /// configuration/bootstrap has made RPC state authoritative. Keep the
    /// request pending without changing the startup phase; once startup is
    /// usable it enters the same modified-buffer inspection as any other quit.
    private var quitQueuedDuringStartup = false
    private var terminationIntent = TerminationIntentStore()
    private var activeQuitAlert: NSAlert?

    struct EditorCommandState: Equatable, Sendable {
        var file = ""
        var modifiable = false
        var readOnly = false
        var bufferType = ""
        var mode = ""
        var canUndo = false
        var canRedo = false

        init() {}

        init(payload: Value) {
            file = payload["file"]?.stringValue ?? ""
            modifiable = payload["modifiable"]?.boolValue ?? false
            readOnly = payload["readonly"]?.boolValue ?? false
            bufferType = payload["buftype"]?.stringValue ?? ""
            mode = payload["mode"]?.stringValue ?? ""
            canUndo = payload["can_undo"]?.boolValue ?? false
            canRedo = payload["can_redo"]?.boolValue ?? false
        }

        var hasVisualSelection: Bool {
            mode == "v" || mode == "V" || mode == "\u{16}"
        }

        var canWrite: Bool {
            !file.isEmpty && modifiable && !readOnly && bufferType.isEmpty
        }
    }

    private(set) var editorCommandState = EditorCommandState()

    /// Keyboard, mouse, paste, and resize traffic share one main-actor queue.
    /// A single drain preserves call order and batches adjacent notifications
    /// into serialized pipe writes without pacing input.
    private var pendingInputCommands: [NvimInputCommand] = []
    private var inputDrainTask: Task<Void, Never>?
    private var inputReady = false

    /// Standard controller for the app and embedding hosts: bundled/managed
    /// binary resolution and the saved configuration selection.
    public convenience init() {
        self.init(nvimBinaryResolver: { try await NvimController.resolveNvimBinary() })
    }

    /// Host-supplied transport: the configuration's process IS the RPC
    /// channel (e.g. an ssh bridge whose stdio connects to a remote
    /// `nvim --headless --listen` socket). Bypasses local binary resolution,
    /// config selection, and the launch plan — the far side owns nvim's
    /// runtimepath and config. The handshake version gate still applies and
    /// validates the nvim actually reached.
    ///
    /// `remoteFilesystem` defaults to true: sourcing workspace file data
    /// through the RPC channel is correct for any transport (the session
    /// always sees its own filesystem), while assuming "local" against an
    /// actually-remote nvim shows the wrong tree. A host bridging to an nvim
    /// on THIS machine may pass false to keep FSEvents watching and native
    /// file operations.
    public convenience init(
        launchConfiguration: NvimLaunchConfiguration,
        remoteFilesystem: Bool = true
    ) {
        self.init(
            customLaunchConfiguration: launchConfiguration,
            remoteFilesystem: remoteFilesystem)
    }

    init(
        nvimBinaryResolver: @escaping @Sendable () async throws -> URL = {
            try await NvimController.resolveNvimBinary()
        },
        configSelectionProvider: @escaping @MainActor () -> NvimConfigSelection = {
            NvimConfigPreferences.loadAndMigrate()
        },
        customLaunchConfiguration: NvimLaunchConfiguration? = nil,
        remoteFilesystem: Bool = false
    ) {
        self.nvimBinaryResolver = nvimBinaryResolver
        self.configSelectionProvider = configSelectionProvider
        self.customLaunchConfiguration = customLaunchConfiguration
        self.hasRemoteFilesystem = remoteFilesystem
        minimapBridge = MinimapBridge(
            surface: nil,
            notify: { [weak self] method, params in
                guard let session = self?.session else { return }
                Task { await session.notify(method, params) }
            })
    }

    private func currentSessionContext() -> SessionContext? {
        guard let session, !sessionExited else { return nil }
        return SessionContext(session: session, generation: sessionGeneration)
    }

    /// Live RPC session for NvimWorkspaceFileSource (sidebar/quick-open
    /// listings on a remote filesystem); nil before startup and after exit.
    /// Requiring only a live stream — not `.running` — lets the sidebar's
    /// first listing overlap the tail of startup: `superlemon.workspace` is
    /// on the runtimepath and side-effect-free before `setup()`.
    var workspaceFileSession: NvimSession? {
        guard let session, !sessionExited else { return nil }
        return session
    }

    private func isCurrent(_ context: SessionContext) -> Bool {
        session === context.session
            && lifecycle.accepts(generation: context.generation)
            && !sessionExited
    }

    public var editorCommandsAvailable: Bool {
        session != nil && !sessionExited && phase == .running
    }

    public var canSaveCurrentBuffer: Bool {
        editorCommandsAvailable && editorCommandState.canWrite
    }

    var canUndo: Bool { editorCommandsAvailable && editorCommandState.canUndo }
    var canRedo: Bool { editorCommandsAvailable && editorCommandState.canRedo }
    var canCopySelection: Bool {
        editorCommandsAvailable && editorCommandState.hasVisualSelection
    }
    var canCutSelection: Bool {
        canCopySelection && editorCommandState.canWrite
    }

    func updateEditorCommandState(_ payload: Value) {
        editorCommandState = EditorCommandState(payload: payload)
    }

    // MARK: - Startup

    /// Spawn nvim, handshake, attach the UI, and start the consumption loops.
    public func start() async {
        await launchSession()
    }

    private func launchSession(safeStart: Bool = false) async {
        guard session == nil, !stopRequested else { return }
        phase = .starting
        safeStartRequested = safeStart
        let generation = lifecycle.beginGeneration()
        var launchedSession: NvimSession?
        do {
            let configuration: NvimLaunchConfiguration
            if let custom = customLaunchConfiguration {
                // Host-supplied transport: no local plan; the far side owns
                // nvim's runtimepath and config.
                activeConfigMode = .custom
                activeConfigPath = nil
                configuration = custom
            } else {
                guard let runtime = Self.runtimeDirectory() else {
                    throw StartupError.runtimeMissing
                }
                let selection = safeStart
                    ? NvimConfigSelection(mode: .managed, customInitPath: nil)
                    : configSelectionProvider()
                let binary = try await nvimBinaryResolver()
                guard lifecycle.accepts(generation: generation), phase == .starting,
                    !stopRequested
                else { return }
                let plan = try NvimLaunchPlan.make(
                    selection: selection,
                    executableURL: binary,
                    runtimeURL: runtime,
                    baseEnvironment: ProcessInfo.processInfo.environment,
                    safeStart: safeStart)
                activeConfigMode = plan.mode
                activeConfigPath = plan.configURL?.path

                configuration = NvimLaunchConfiguration(
                    binaryURL: plan.executableURL,
                    arguments: plan.arguments,
                    workingDirectory: Self.workingDirectory(),
                    environment: plan.environment
                )
            }
            let session = NvimSession(configuration: configuration)
            launchedSession = session
            // Clipboard provider handlers must be in place before any bytes
            // flow — the runtime plugin registers g:clipboard at setup.
            await session.setRequestHandler(Self.makeRequestHandler())
            guard lifecycle.accepts(generation: generation), phase == .starting,
                !stopRequested
            else { return }

            self.session = session
            sessionExited = false
            runtimeReady = false
            pendingFirstFlush = nil
            firstFlushDelivered = false

            // Start consuming before any bytes flow so nothing is dropped.
            consumeUIEvents(from: session, generation: generation)
            consumeLifecycleEvents(from: session, generation: generation)
            consumeNotifications(from: session, generation: generation)
            let context = SessionContext(session: session, generation: generation)
            guard isCurrent(context), phase == .starting else { return }

            try await session.start()
            guard isCurrent(context), phase == .starting else { return }
            let info = try await session.handshake()
            guard isCurrent(context), phase == .starting else { return }
            guard Self.isSupportedNvimVersion(info.version) else {
                throw StartupError.unsupportedNvimVersion(info.version)
            }
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
            guard isCurrent(context), phase == .starting else { return }
            attached = true
            inputReady = true
            scheduleInputDrainIfNeeded()
            // The view may have been laid out while attaching.
            sendResizeIfNeeded()
            try await validateCustomConfiguration(session)
            guard isCurrent(context), phase == .starting else { return }
            try await bootstrapRuntimePlugin(session)
            guard isCurrent(context), phase == .starting else { return }
            // Startup/config can flush partial frames before the bridge has
            // installed its final chrome and notification state. Discard those
            // candidates, force one authoritative redraw through the now-ready
            // bridge, and only then allow smoke/readiness delivery.
            pendingFirstFlush = nil
            _ = try await session.request(
                "nvim_command", [.string("redraw!")], timeout: .seconds(5))
            guard isCurrent(context), phase == .starting else { return }
            runtimeReady = true
            phase = .running
            deliverFirstFlushIfReady()
            if hasRemoteFilesystem {
                // Off the startup path: a slow/failed cwd probe must not
                // delay first-flush consumers or a queued quit.
                Task { [weak self] in
                    await self?.adoptSessionWorkingDirectory(context)
                }
            }
            beginQueuedStartupQuitIfNeeded(context)
        } catch {
            guard sessionGeneration == generation else { return }
            if sessionExited || phase == .terminated { return }
            if terminationIntent.isPending,
                let context = currentSessionContext(),
                launchedSession === context.session
            {
                // Startup failed, but a normal quit is already pending and the
                // RPC session may still own modified buffers. Run the same
                // bounded inspection/Save-Cancel-Discard path as a healthy
                // session. A dead stream is folded into its terminal outcome;
                // an unresponsive stream presents the explicit force choice.
                quitQueuedDuringStartup = false
                if !quitRequestInFlight { quitRequestInFlight = true }
                beginQuitInspection(context)
                return
            }
            if phase == .stopping || stopRequested {
                phase = .stopping
                if let launchedSession {
                    let outcome = await launchedSession.shutdown()
                    if session === launchedSession, !sessionExited {
                        handleSessionTermination(launchedSession, outcome: outcome)
                    }
                }
                return
            }
            // Detach the failed generation before reaping it so its terminal
            // event cannot race this startup-error path and show two alerts.
            session = nil
            lifecycle.beginGeneration()
            if let launchedSession { _ = await launchedSession.shutdown() }
            clearSessionState()
            phase = .recovering
            handleStartupFailure(error)
        }
    }

    /// Neovim reports errors thrown by a `-u custom` file through v:errmsg
    /// while otherwise continuing to serve RPC. Promote that startup state to
    /// the same visible recovery path as a managed-config source failure.
    private func validateCustomConfiguration(_ session: NvimSession) async throws {
        guard activeConfigMode == .custom else { return }
        try await Self.validateCustomConfiguration(session, path: activeConfigPath)
    }

    nonisolated static func validateCustomConfiguration(
        _ session: NvimSession, path: String?
    ) async throws {
        let diagnostic = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    """
                    local message = vim.v.errmsg or ''
                    return {
                      custom = vim.g.superlemon_custom_config,
                      message = message,
                      messages = vim.api.nvim_exec2('messages', { output = true }).output,
                    }
                    """),
                .array([]),
            ],
            timeout: .seconds(5))
        if let custom = diagnostic["custom"], custom.mapValue != nil {
            let state = custom["state"]?.stringValue ?? "missing"
            if state == "loaded" { return }
            let customError = custom["error"]
            throw StartupError.config(
                path: customError?["path"]?.stringValue
                    ?? custom["path"]?.stringValue ?? path,
                message: customError?["message"]?.stringValue
                    ?? "The selected configuration did not finish loading (state: \(state)).")
        }
        let message = diagnostic["message"]?.stringValue ?? ""
        guard !message.isEmpty else { return }
        let context = diagnostic["messages"]?.stringValue ?? ""
        throw StartupError.config(
            path: path,
            message: context.isEmpty ? message : context)
    }

    /// Bridge setup is deliberately configuration-free: every startup file
    /// has already run, and this call only installs GUI adapters from the
    /// final user-visible option/global state.
    private func bootstrapRuntimePlugin(_ session: NvimSession) async throws {
        guard let channelID else { throw StartupError.bridgeNotReady("missing channel") }
        let result = try await session.request(
            "nvim_exec_lua",
            [
                .string(
                    "local chan, mode = ...\n"
                        + "vim.g.superlemon_config_mode = vim.g.superlemon_config_mode or mode\n"
                        + "return require('superlemon').setup(chan)"),
                .array([
                    .int(Int64(channelID)),
                    .string(safeStartRequested ? "safe" : activeConfigMode.rawValue),
                ]),
            ],
            timeout: .seconds(5))

        guard result["ready"]?.boolValue == true else {
            throw StartupError.bridgeNotReady(result["reason"]?.stringValue ?? "unknown reason")
        }
        if result["config"]?["state"]?.stringValue == "error" {
            let error = result["config"]?["error"]
            throw StartupError.config(
                path: error?["path"]?.stringValue ?? result["config"]?["path"]?.stringValue,
                message: error?["message"]?.stringValue ?? "unknown configuration error")
        }
    }

    /// Remote transports start with a host-guessed project root, but the
    /// session's own cwd is authoritative for the filesystem it sees.
    /// Re-root the native workspace chrome once startup completes; failure
    /// keeps the host-provided root (the sidebar surfaces its own listing
    /// error and Quick Open stays empty until the next successful refresh).
    private func adoptSessionWorkingDirectory(_ context: SessionContext) async {
        guard
            let reply = try? await context.session.request(
                "nvim_exec_lua",
                [.string("return vim.fn.getcwd()"), .array([])],
                timeout: .seconds(5)),
            isCurrent(context),
            let path = reply.stringValue, !path.isEmpty
        else { return }
        chrome?.setProjectRoot(URL(fileURLWithPath: path, isDirectory: true))
    }

    nonisolated static func isSupportedNvimVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        guard parts.count >= 2 else { return false }
        // Floor 0.11: a static audit of every nvim API the runtime
        // calls found nothing newer than vim.fs.relpath (0.11); the redraw
        // decoder tolerates older event payloads. 0.10 and below would
        // need a compat prelude (vim.fs.joinpath/vim.uv/vim.system).
        return parts[0] > 0 || parts[1] >= 11
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
    public nonisolated static func runtimeDirectory() -> URL? {
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

    /// Binary discovery per DESIGN §3. Packaged builds use the bundled copy.
    /// Source/debug builds may inspect their inherited PATH directly; startup
    /// never invokes a login shell. SUPERLEMON_NVIM is an explicit developer
    /// and test override in either environment.
    private nonisolated static func resolveNvimBinary() async throws -> URL {
        try await Task.detached(priority: .userInitiated) { () throws -> URL in
            let fm = FileManager.default
            let environment = ProcessInfo.processInfo.environment
            if let override = environment["SUPERLEMON_NVIM"], !override.isEmpty {
                guard fm.isExecutableFile(atPath: override) else {
                    throw StartupError.nvimNotFound
                }
                return URL(fileURLWithPath: override)
            }
            let executable = URL(fileURLWithPath: Bundle.main.executablePath ?? "")
            let packagedCandidates = [
                executable.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Helpers/nvim/bin/nvim"),  // packaged distribution
                executable.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Helpers/nvim"),  // legacy packaged layout
            ]
            if let found = packagedCandidates.first(where: {
                fm.isExecutableFile(atPath: $0.path)
            }) {
                return found
            }

            // An .app is a distribution build: silently borrowing a host
            // Neovim would make the downloadable artifact non-self-contained.
            if Bundle.main.bundleURL.pathExtension == "app" {
                throw StartupError.nvimNotFound
            }

            var candidates = [
                executable.deletingLastPathComponent().appendingPathComponent("nvim")
            ]
            for directory in (environment["PATH"] ?? "").split(separator: ":") {
                candidates.append(
                    URL(fileURLWithPath: String(directory), isDirectory: true)
                        .appendingPathComponent("nvim"))
            }
            candidates += [
                URL(fileURLWithPath: "/opt/homebrew/bin/nvim"),
                URL(fileURLWithPath: "/usr/local/bin/nvim"),
            ]
            guard let found = candidates.first(where: {
                fm.isExecutableFile(atPath: $0.path)
            }) else { throw StartupError.nvimNotFound }
            return found
        }.value
    }

    public nonisolated static func workingDirectory() -> URL {
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
        let message = error.localizedDescription
        if let startupFailureHandler {
            startupFailureHandler(message)
            return
        }
        guard let window else {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not start Neovim"
        alert.informativeText = message
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Start Safely")
        alert.addButton(withTitle: "Quit")
        let recoveryGeneration = sessionGeneration
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.phase == .recovering, self.session == nil,
                self.sessionGeneration == recoveryGeneration
            else { return }
            switch response {
            case .alertFirstButtonReturn:
                Task { await self.launchSession() }
            case .alertSecondButtonReturn:
                Task { await self.launchSession(safeStart: true) }
            default:
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Consumption loop: redraw events

    private func consumeUIEvents(from session: NvimSession, generation: Int) {
        uiTask = Task { [weak self] in
            for await batch in session.uiEvents {
                guard let self, self.session === session,
                    self.sessionGeneration == generation
                else { return }
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
    private func consumeNotifications(from session: NvimSession, generation: Int) {
        notificationTask = Task { [weak self] in
            for await notification in session.notifications {
                guard let self, self.session === session,
                    self.sessionGeneration == generation
                else { return }
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
        inputHost?.updateAccessibility(with: flush)

        if flush.title != lastTitle {
            lastTitle = flush.title
            window?.title = flush.title.isEmpty ? "Superlemon" : flush.title
        }
        applyWindowBackground(flush.highlights.defaultBackground)
        applyGuifontIfChanged()

        pendingFirstFlush = flush
        deliverFirstFlushIfReady()
    }

    /// Readiness is stronger than "nvim drew something": config validation,
    /// UI attachment, and bridge setup must all have completed before smoke or
    /// callers can treat a frame as authoritative.
    private func deliverFirstFlushIfReady() {
        guard runtimeReady, !firstFlushDelivered, let flush = pendingFirstFlush else { return }
        firstFlushDelivered = true
        pendingFirstFlush = nil
        onFirstFlush?(flush)
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

    private func consumeLifecycleEvents(from session: NvimSession, generation: Int) {
        lifecycleTask = Task { [weak self] in
            for await outcome in session.terminationEvents {
                guard let self, self.session === session,
                    self.sessionGeneration == generation
                else { return }
                self.handleSessionTermination(session, outcome: outcome)
            }
        }
    }

    private func handleSessionTermination(
        _ exitedSession: NvimSession, outcome: NvimTermination
    ) {
        guard session === exitedSession else { return }
        // Startup owns failures until the launch sequence reaches `.running`.
        // Its awaited request will fail from the same terminal outcome and
        // present one startup-recovery sheet; consuming the lifecycle event
        // here as well would race a second recovery sheet onto the window.
        if phase == .starting {
            resetInputQueue()
            return
        }
        sessionExited = true
        quitRequestInFlight = false
        resetInputQueue()
        if let exitHandler {
            exitHandler(outcome.exitCode ?? 1, outcome.stderrTail)
            return
        }
        dismissActiveQuitAlert()
        clearSessionState()
        if let intent = terminationIntent.take() {
            if case .relaunch(let launchReplacement) = intent {
                do {
                    try launchReplacement()
                } catch {
                    replyToApplicationTermination(false)
                    phase = .recovering
                    presentRecoveryChoices(
                        title: "Couldn’t relaunch Superlemon",
                        detail: error.localizedDescription)
                    return
                }
            }
            phase = .terminated
            window?.close()
            replyToApplicationTermination(true)
        } else if stopRequested {
            phase = .terminated
            window?.close()
        } else if outcome.cause == .processExit, outcome.exitCode == 0 {
            phase = .terminated
            window?.close()
            NSApp.terminate(nil)
        } else {
            phase = .recovering
            presentRecoveryAlert(outcome)
        }
    }

    private func presentRecoveryAlert(_ outcome: NvimTermination) {
        let title: String
        switch outcome.cause {
        case .processExit:
            title = "Neovim exited unexpectedly"
        case .protocolError:
            title = "Neovim sent invalid protocol data"
        case .ioFailure:
            title = "The Neovim connection failed"
        case .backpressureExceeded:
            title = "Neovim overwhelmed the UI connection"
        case .requestedShutdown:
            title = "Neovim stopped unexpectedly"
        }
        var detail = outcome.exitCode.map { "Exit code: \($0)" } ?? "No exit code was reported."
        if !outcome.stderrTail.isEmpty {
            detail += "\n\n" + String(outcome.stderrTail.suffix(2_000))
        }
        presentRecoveryChoices(title: title, detail: detail)
    }

    private func presentRecoveryChoices(title: String, detail: String) {
        guard let window else {
            NSApp.terminate(nil)
            return
        }
        let generation = sessionGeneration
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Start Safely")
        alert.addButton(withTitle: "Quit")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.phase == .recovering, self.session == nil,
                self.sessionGeneration == generation
            else { return }
            switch response {
            case .alertFirstButtonReturn:
                Task { await self.launchSession() }
            case .alertSecondButtonReturn:
                Task { await self.launchSession(safeStart: true) }
            default:
                NSApp.terminate(nil)
            }
        }
    }

    private func clearSessionState() {
        inputHost?.discardMarkedTextForSessionChange()
        uiTask?.cancel()
        lifecycleTask?.cancel()
        notificationTask?.cancel()
        uiTask = nil
        lifecycleTask = nil
        notificationTask = nil
        session = nil
        channelID = nil
        attached = false
        inputReady = false
        quitRequestInFlight = false
        quitQueuedDuringStartup = false
        editorCommandState = EditorCommandState()
    }

    /// Final process-ownership backstop. The normal app quit path first asks
    /// Neovim to exit cleanly; this prevents a restart and terminates any
    /// remaining child when AppKit is already shutting down.
    public func stop() {
        stopRequested = true
        phase = .stopping
        resetInputQueue()
        session?.forceKillNow()
    }

    // MARK: - Quit flow (DESIGN §3)

    /// Backs `applicationShouldTerminate`: the app owns the native modified-
    /// buffer choice, while actual termination waits for nvim's lifecycle exit.
    public func handleTerminationRequest() -> NSApplication.TerminateReply {
        if phase == .starting, session == nil {
            // Binary/config resolution is still suspended. Invalidate that
            // generation now so it cannot spawn a child after AppKit proceeds.
            stopRequested = true
            phase = .stopping
            lifecycle.beginGeneration()
        }
        if sessionExited || session == nil {
            do {
                if case .relaunch(let launchReplacement) = terminationIntent.take() {
                    try launchReplacement()
                }
                return .terminateNow
            } catch {
                terminationIntent.cancel()
                phase = .recovering
                presentRecoveryChoices(
                    title: "Couldn’t relaunch Superlemon", detail: error.localizedDescription)
                return .terminateCancel
            }
        }
        terminationIntent.requestQuitIfNeeded()
        requestQuit()
        return .terminateLater
    }

    /// Settings relaunch goes through the same dirty-buffer decision as Quit.
    /// The replacement is created only after Neovim has actually exited.
    public func requestRelaunch(_ launchReplacement: @escaping () throws -> Void) {
        terminationIntent.requestRelaunch(launchReplacement)
        requestApplicationTermination()
    }

    /// Quit without ever blocking on nvim (a blocking `:confirm qa` request
    /// wedged termination: AppKit ignores further ⌘Q while a .terminateLater
    /// reply is pending, so a missed in-grid prompt looked like a lockup and
    /// grayed the Quit item). Instead: query modified buffers with a hang
    /// timeout, then drive a NATIVE save/discard/cancel dialog; every path
    /// resolves the pending termination reply.
    public func requestQuit() {
        guard let context = currentSessionContext(), !quitRequestInFlight else { return }
        if phase == .starting {
            quitRequestInFlight = true
            quitQueuedDuringStartup = true
            return
        }
        guard phase == .running || phase == .recovering else { return }
        quitRequestInFlight = true
        beginQuitInspection(context)
    }

    private func beginQueuedStartupQuitIfNeeded(_ context: SessionContext) {
        guard quitQueuedDuringStartup, quitRequestInFlight,
            isCurrent(context), phase == .running
        else { return }
        quitQueuedDuringStartup = false
        beginQuitInspection(context)
    }

    private func beginQuitInspection(_ context: SessionContext) {
        phase = .inspectingQuit
        Task { [weak self] in
            guard let self else { return }
            await self.runQuitFlow(context)
            if self.isCurrent(context) { self.quitRequestInFlight = false }
        }
    }

    struct ModifiedBuffer: Sendable {
        let handle: Int
        let name: String
        let displayName: String
        let listed: Bool
        let bufferType: String
        let readOnly: Bool

        init?(_ value: Value) {
            guard let handle = value["handle"]?.intValue else { return nil }
            self.handle = handle
            name = value["name"]?.stringValue ?? ""
            displayName = value["display_name"]?.stringValue ?? "[No Name]"
            listed = value["listed"]?.boolValue ?? false
            bufferType = value["buftype"]?.stringValue ?? ""
            readOnly = value["readonly"]?.boolValue ?? false
        }
    }

    struct BufferWriteFailure: Sendable {
        let displayName: String
        let message: String

        init?(_ value: Value) {
            guard let message = value["error"]?.stringValue else { return nil }
            displayName = value["display_name"]?.stringValue ?? "[No Name]"
            self.message = message
        }
    }

    nonisolated static func queryModifiedBuffers(
        _ session: NvimSession
    ) async throws -> [ModifiedBuffer] {
        let lua = """
            local buffers = {}
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(b)
                  and vim.api.nvim_buf_is_loaded(b)
                  and vim.bo[b].modified then
                local name = vim.api.nvim_buf_get_name(b)
                local display = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
                if vim.bo[b].buftype ~= "" then
                  display = display .. " (" .. vim.bo[b].buftype .. ")"
                end
                buffers[#buffers + 1] = {
                  handle = b,
                  name = name,
                  display_name = display,
                  listed = vim.bo[b].buflisted,
                  buftype = vim.bo[b].buftype,
                  readonly = vim.bo[b].readonly,
                }
              end
            end
            return buffers
            """
        let reply = try await session.request(
            "nvim_exec_lua", [.string(lua), .array([])], timeout: .seconds(2))
        return reply.arrayValue?.compactMap(ModifiedBuffer.init) ?? []
    }

    private func runQuitFlow(_ context: SessionContext) async {
        do {
            let modified = try await Self.queryModifiedBuffers(context.session)
            guard isCurrent(context) else { return }
            guard !modified.isEmpty else {
                phase = .stopping
                // Intentionally no bang: an edit or refusing autocommand that
                // occurs after inspection must still keep the application open.
                do {
                    _ = try await context.session.request(
                        "nvim_command", [.string("qa")], timeout: .seconds(2))
                } catch {
                    guard isCurrent(context) else { return }
                    phase = .running
                    cancelQuit(context)
                    presentInfoAlert(
                        "Neovim refused to quit",
                        detail: error.localizedDescription)
                }
                return
            }
            phase = .awaitingQuitChoice
            presentUnsavedAlert(modified, context: context)
        } catch NvimError.requestTimedOut {
            guard isCurrent(context) else { return }
            phase = .awaitingQuitChoice
            presentUnresponsiveAlert(context)
        } catch let error as NvimError {
            switch error {
            case .sessionNotRunning, .sessionTerminated, .protocolError,
                .ioFailure, .backpressureExceeded:
                // There is no live RPC endpoint left to protect. Fold the
                // already-terminal (or never-started) session through the one
                // lifecycle completion path so AppKit's pending termination
                // reply and any relaunch intent are each resolved once.
                await finishQuitAfterTerminalSession(context)
            case .rpc, .handshakeFailed, .requestTimedOut:
                guard isCurrent(context) else { return }
                phase = .running
                cancelQuit(context)
                presentInfoAlert(
                    "Couldn’t inspect unsaved buffers",
                    detail: error.localizedDescription)
            }
        } catch {
            guard isCurrent(context) else { return }
            phase = .running
            cancelQuit(context)
            presentInfoAlert(
                "Couldn’t inspect unsaved buffers",
                detail: error.localizedDescription)
        }
    }

    private func finishQuitAfterTerminalSession(_ context: SessionContext) async {
        guard isCurrent(context) else { return }
        phase = .stopping
        let outcome = await context.session.shutdown()
        // The lifecycle stream may have delivered the same exactly-once
        // outcome while shutdown was suspended. Only synthesize delivery for
        // an idle/already-terminated session that remains current.
        guard isCurrent(context) else { return }
        handleSessionTermination(context.session, outcome: outcome)
    }

    /// Native Save All / Discard All / Cancel — replaces nvim's in-grid
    /// y/n/c confirm prompt for the quit path.
    private func presentUnsavedAlert(_ buffers: [ModifiedBuffer], context: SessionContext) {
        guard isCurrent(context) else { return }
        guard let window else {
            cancelQuit(context)  // headless: never discard silently
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            buffers.count == 1
            ? "“\(buffers[0].displayName)” has unsaved changes"
            : "\(buffers.count) buffers have unsaved changes"
        let shown = buffers.prefix(6).map(\.displayName).joined(separator: "\n")
        alert.informativeText =
            buffers.count > 6 ? shown + "\n… and \(buffers.count - 6) more" : shown
        alert.addButton(withTitle: "Save All & Quit")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard All & Quit")
        activeQuitAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeQuitAlert = nil
            guard self.isCurrent(context) else { return }
            switch response {
            case .alertFirstButtonReturn:  // Save All & Quit
                Task {
                    await self.saveAllAndContinueQuit(context)
                }
            case .alertThirdButtonReturn:  // Discard All & Quit
                self.phase = .stopping
                Task {
                    do {
                        _ = try await context.session.request(
                            "nvim_command", [.string("qa!")], timeout: .seconds(2))
                    } catch {
                        guard self.isCurrent(context) else { return }
                        self.phase = .running
                        self.cancelQuit(context)
                        self.presentInfoAlert(
                            "Neovim refused to quit",
                            detail: error.localizedDescription)
                    }
                }
            default:  // Cancel
                self.cancelQuit(context)
            }
        }
    }

    private func saveAllAndContinueQuit(_ context: SessionContext) async {
        guard isCurrent(context) else { return }
        phase = .saving
        do {
            let failures = try await Self.writeModifiedBuffers(context.session)
            guard isCurrent(context) else { return }
            guard failures.isEmpty else {
                phase = .running
                cancelQuit(context)
                let detail = failures.prefix(8).map {
                    "\($0.displayName): \($0.message)"
                }.joined(separator: "\n")
                presentInfoAlert("Couldn’t save all buffers", detail: detail)
                return
            }

            // Reprobe after all writes. This protects a buffer changed by an
            // autocommand or concurrent editor action during the save pass.
            phase = .inspectingQuit
            let stillModified = try await Self.queryModifiedBuffers(context.session)
            guard isCurrent(context) else { return }
            if stillModified.isEmpty {
                phase = .stopping
                _ = try await context.session.request(
                    "nvim_command", [.string("qa")], timeout: .seconds(2))
            } else {
                phase = .awaitingQuitChoice
                presentUnsavedAlert(stillModified, context: context)
            }
        } catch {
            guard isCurrent(context) else { return }
            phase = .running
            cancelQuit(context)
            presentInfoAlert(
                "Couldn’t save all buffers",
                detail: error.localizedDescription)
        }
    }

    nonisolated static func writeModifiedBuffers(
        _ session: NvimSession
    ) async throws -> [BufferWriteFailure] {
        let lua = """
            local failures = {}
            for _, b in ipairs(vim.api.nvim_list_bufs()) do
              if vim.api.nvim_buf_is_valid(b)
                  and vim.api.nvim_buf_is_loaded(b)
                  and vim.bo[b].modified then
                local name = vim.api.nvim_buf_get_name(b)
                local display = name ~= "" and vim.fn.fnamemodify(name, ":t") or "[No Name]"
                if vim.bo[b].buftype ~= "" then
                  display = display .. " (" .. vim.bo[b].buftype .. ")"
                end
                local ok, err = pcall(vim.api.nvim_buf_call, b, function()
                  vim.cmd.write()
                end)
                if not ok then
                  failures[#failures + 1] = {
                    handle = b,
                    display_name = display,
                    error = tostring(err),
                  }
                end
              end
            end
            return failures
            """
        let reply = try await session.request(
            "nvim_exec_lua", [.string(lua), .array([])], timeout: .seconds(30))
        return reply.arrayValue?.compactMap(BufferWriteFailure.init) ?? []
    }

    /// nvim didn't answer within the guard window (stuck at a blocking
    /// prompt or hung): offer a way out that always resolves.
    private func presentUnresponsiveAlert(_ context: SessionContext) {
        guard isCurrent(context) else { return }
        guard let window else {
            cancelQuit(context)
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
        activeQuitAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.activeQuitAlert = nil
            guard self.isCurrent(context) else { return }
            if response == .alertSecondButtonReturn {
                self.phase = .stopping
                Task { _ = await context.session.shutdown() }  // exit → lifecycle → reply
            } else {
                self.cancelQuit(context)
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

    private func performSessionOperation(
        failureTitle: String,
        _ operation: @escaping @MainActor (NvimSession) async throws -> Void
    ) {
        guard let context = currentSessionContext() else { return }
        Task { [weak self] in
            do {
                try await operation(context.session)
            } catch {
                guard let self, self.isCurrent(context) else { return }
                self.presentInfoAlert(failureTitle, detail: error.localizedDescription)
            }
        }
    }

    private func dismissActiveQuitAlert() {
        guard let alert = activeQuitAlert else { return }
        activeQuitAlert = nil
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .abort)
        } else {
            alert.window.orderOut(nil)
        }
    }

    private func cancelQuit(_ context: SessionContext? = nil) {
        if let context, !isCurrent(context) { return }
        quitQueuedDuringStartup = false
        phase = session == nil ? .terminated : .running
        let applicationTerminationWasPending = terminationIntent.cancel()
        guard applicationTerminationWasPending else { return }
        replyToApplicationTermination(false)
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

        guard let context = currentSessionContext() else { return }
        while !Task.isCancelled, inputReady, isCurrent(context),
            !pendingInputCommands.isEmpty
        {
            let commands = pendingInputCommands
            pendingInputCommands.removeAll(keepingCapacity: true)
            var notifications: [NvimSession.OutgoingNotification] = []
            for command in commands {
                if case .paste(let text) = command {
                    if !notifications.isEmpty {
                        await context.session.notifyBatch(notifications)
                        guard isCurrent(context) else { return }
                        notifications.removeAll(keepingCapacity: true)
                    }
                    do {
                        _ = try await context.session.request(
                            "nvim_paste", [.string(text), .bool(true), .int(-1)],
                            timeout: .seconds(30))
                    } catch {
                        guard isCurrent(context) else { return }
                        presentInfoAlert(
                            "Couldn’t paste text",
                            detail: error.localizedDescription)
                    }
                } else {
                    notifications.append(contentsOf: command.notifications)
                }
            }
            if !notifications.isEmpty {
                await context.session.notifyBatch(notifications)
                guard isCurrent(context) else { return }
            }
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

    /// Embedding hosts (EditorHostNSView/EditorSurface) push a native
    /// font-size override; nil returns to the guifont/linespace values from
    /// the active Neovim configuration.
    func overrideFontSize(_ size: CGFloat?) {
        guard surface != nil else { return }
        var spec = configuredFontSpec
        renderingSettings.apply(to: &spec)
        if let size {
            spec.size = max(6, min(72, size))
        }
        applyFontSpec(spec)
    }

    /// Native tab strip: switch to a buffer (CONTRACT.md superlemon.buffers).
    func switchToBuffer(_ bufnr: Int) {
        performSessionOperation(failureTitle: "Couldn’t switch buffers") { session in
            _ = try await session.request(
                "nvim_set_current_buf", [.int(Int64(bufnr))],
                timeout: .seconds(5))
        }
    }

    /// Native tab strip: close a buffer, letting nvim confirm unsaved edits.
    func closeBuffer(_ bufnr: Int) {
        performSessionOperation(failureTitle: "Couldn’t close buffer") { session in
            _ = try await session.request(
                "nvim_command", [.string("confirm bdelete \(bufnr)")],
                timeout: .seconds(5))
        }
    }

    /// View menu → plugin truth: toggle native chrome (CONTRACT.md).
    public func toggleNativeChrome(_ part: String) {
        guard currentSessionContext() != nil else {
            NSLog("superlemon: toggleNativeChrome(\(part)) — no session")
            return
        }
        performSessionOperation(failureTitle: "Couldn’t change editor chrome") { session in
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string("require('superlemon').chrome_toggle(...)"),
                    .array([.string(part)]),
                ],
                timeout: .seconds(5))
        }
    }

    /// Open a file through nvim (`:drop` keeps buffer state coherent,
    /// DESIGN §14.1); fnameescape guards spaces/specials.
    public func openFile(_ absolutePath: String) {
        performSessionOperation(failureTitle: "Couldn’t open file") { session in
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string("vim.cmd.drop(vim.fn.fnameescape(...))"),
                    .array([.string(absolutePath)]),
                ],
                timeout: .seconds(5))
        }
    }

    /// Change Neovim's global working directory, then re-root the native
    /// sidebar and quick-open index to the same folder. Neovim performs the
    /// change so `DirChanged` autocmds and user configuration still run.
    public func openFolder(_ absolutePath: String) {
        guard let context = currentSessionContext() else { return }
        let root = URL(fileURLWithPath: absolutePath, isDirectory: true).standardizedFileURL
        Task { [weak self] in
            do {
                let currentDirectory = try await context.session.request(
                    "nvim_exec_lua",
                    [
                        .string(
                            "local path = ...\n"
                                + "vim.api.nvim_set_current_dir(path)\n"
                                + "return vim.fn.getcwd()"),
                        .array([.string(root.path)]),
                    ],
                    timeout: .seconds(5))
                guard let self, self.isCurrent(context) else { return }
                // Use Neovim's canonical cwd (not the panel's possibly
                // symlinked URL) so relative native paths resolve identically.
                let authoritativeRoot = currentDirectory.stringValue
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? root
                self.chrome?.setProjectRoot(authoritativeRoot)
            } catch {
                guard let self, self.isCurrent(context) else { return }
                self.presentInfoAlert(
                    "Couldn’t open folder",
                    detail: error.localizedDescription)
            }
        }
    }

    /// Absolute name of the current buffer, or nil for an unnamed/special
    /// buffer. Used only to seed the native Save As panel; Neovim remains
    /// responsible for writing and renaming the buffer.
    public func currentBufferPath() async -> String? {
        guard let context = currentSessionContext() else { return nil }
        guard
            let name = try? await context.session.request(
                "nvim_buf_get_name", [.int(0)], timeout: .seconds(5)),
            isCurrent(context),
            let path = name.stringValue,
            !path.isEmpty,
            !path.contains("://")
        else { return nil }
        return path
    }

    /// Save the current buffer under a new name. NSSavePanel has already
    /// confirmed replacement, hence `bang = true`; routing the operation
    /// through `nvim_cmd` preserves encoding, autocmds, undo, and buffer state.
    public func saveFile(as absolutePath: String) {
        performSessionOperation(failureTitle: "Couldn’t save file") { session in
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string(
                        "vim.api.nvim_cmd({ cmd = 'saveas', args = { ... }, bang = true }, {})"
                    ),
                    .array([.string(absolutePath)]),
                ],
                timeout: .seconds(30))
        }
    }

    /// Semantic File ▸ Save. Unlike forwarding <D-s>, this cannot be changed
    /// into an unrelated action by a user mapping.
    public func saveCurrentBuffer() {
        performEditorCommand(
            "write", failureTitle: "Couldn’t save file", timeout: .seconds(30))
    }

    func performUndo() {
        performEditorCommand("undo", failureTitle: "Couldn’t undo")
    }

    func performRedo() {
        performEditorCommand("redo", failureTitle: "Couldn’t redo")
    }

    private func performEditorCommand(
        _ command: String,
        failureTitle: String,
        timeout: Duration = .seconds(5)
    ) {
        performSessionOperation(failureTitle: failureTitle) { session in
            _ = try await session.request(
                "nvim_command", [.string(command)], timeout: timeout)
        }
    }

    /// Native Cut/Copy remain selection-sensitive and write through Neovim's
    /// clipboard register so its normal register/autocommand semantics hold.
    func copySelection(cut: Bool) {
        performSessionOperation(
            failureTitle: cut ? "Couldn’t cut selection" : "Couldn’t copy selection"
        ) { session in
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string(
                        """
                        local cut = ...
                        local mode = vim.fn.mode()
                        if not mode:match('^[vV\\22]') then error('No selection') end
                        vim.cmd.normal({ args = { cut and '"+d' or '"+y' }, bang = true })
                        """),
                    .array([.bool(cut)]),
                ],
                timeout: .seconds(5))
        }
    }

    func selectAllText() {
        sendInput("<Esc>ggVG")
    }

    /// Enter Neovim's search prompt from insert, command-line, terminal, or
    /// normal mode. CTRL-\ CTRL-N is Neovim's mode-independent return to
    /// Normal mode; the following slash cannot become literal inserted text.
    nonisolated static let beginFindInput = "<C-\\><C-N><Esc>/"

    func beginFind() {
        sendInput(Self.beginFindInput)
    }

    /// Create a durable user-owned settings file from the bundled annotated
    /// template on first use, then open it in Neovim. The managed init sources
    /// `$XDG_CONFIG_HOME/superlemon/init.vim` after the bundled baseline.
    public func openConfiguration(
        _ selection: NvimConfigSelection,
        managedTemplatePath: String
    ) {
        guard let context = currentSessionContext() else { return }
        let activeMode = activeConfigMode
        Task { [weak self] in
            do {
                let script: String
                let arguments: [Value]
                switch selection.mode {
                case .managed:
                    script = """
                        local template = ...
                        local target = require('superlemon.settings').ensure_user_config(template)
                        vim.cmd.drop(vim.fn.fnameescape(target))
                        return target
                        """
                    arguments = [.string(managedTemplatePath)]
                case .user:
                    let environment = ProcessInfo.processInfo.environment
                    let fallback = await Task.detached(priority: .userInitiated) {
                        NvimLaunchPlan.preferredUserInitURL(environment: environment).path
                    }.value
                    guard let self, self.isCurrent(context) else { return }
                    script = """
                        local fallback, use_active_vimrc = ...
                        local target = use_active_vimrc and vim.env.MYVIMRC or fallback
                        if not target or target == '' then target = fallback end
                        vim.fn.mkdir(vim.fn.fnamemodify(target, ':h'), 'p')
                        if not vim.uv.fs_stat(target) then vim.fn.writefile({}, target) end
                        vim.cmd.drop(vim.fn.fnameescape(target))
                        return target
                        """
                    arguments = [.string(fallback), .bool(activeMode == .user)]
                case .custom:
                    guard let path = selection.customInitPath else {
                        throw NvimLaunchPlan.PlanError.missingCustomInitPath
                    }
                    script = """
                        local target = ...
                        vim.cmd.drop(vim.fn.fnameescape(target))
                        return target
                        """
                    arguments = [.string(path)]
                }
                _ = try await context.session.request(
                    "nvim_exec_lua",
                    [.string(script), .array(arguments)],
                    timeout: .seconds(5))
            } catch {
                guard let self, self.isCurrent(context) else { return }
                self.presentInfoAlert(
                    "Couldn’t open configuration",
                    detail: error.localizedDescription)
            }
        }
    }

    /// Sidebar single-click: open as a PREVIEW buffer (VS Code/Sublime
    /// semantics — see superlemon.preview and CONTRACT.md).
    func previewFile(_ absolutePath: String) {
        performSessionOperation(failureTitle: "Couldn’t preview file") { session in
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string("require('superlemon.preview').open(...)"),
                    .array([.string(absolutePath)]),
                ],
                timeout: .seconds(5))
        }
    }

    /// Sidebar double-click: open pinned (promotes if currently previewed).
    func openFilePermanently(_ absolutePath: String) {
        performSessionOperation(failureTitle: "Couldn’t open file") { session in
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string("require('superlemon.preview').open_permanent(...)"),
                    .array([.string(absolutePath)]),
                ],
                timeout: .seconds(5))
        }
    }

    /// Double-click (file or tab): pin the preview buffer permanently.
    func promoteBuffer(_ bufnr: Int) {
        performSessionOperation(failureTitle: "Couldn’t keep buffer open") { session in
            _ = try await session.request(
                "nvim_exec_lua",
                [
                    .string("require('superlemon.preview').promote(...)"),
                    .array([.int(Int64(bufnr))]),
                ],
                timeout: .seconds(5))
        }
    }

    /// superlemon.ui callback dispatch (runtime/CONTRACT.md): blocking
    /// request into the Lua-side callback registry. Returns the callback's
    /// return value, or nil on any error (freed id, Lua error, no session).
    func dispatchUICallback(_ id: Int, payload: [(Value, Value)]) async -> Value? {
        guard let context = currentSessionContext() else { return nil }
        guard let value = try? await context.session.request(
                "nvim_exec_lua",
                [
                    .string("return require('superlemon.ui')._dispatch(...)"),
                    .array([.int(Int64(id)), .map(payload)]),
                ],
                timeout: .seconds(5)),
            isCurrent(context)
        else { return nil }
        return value
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
