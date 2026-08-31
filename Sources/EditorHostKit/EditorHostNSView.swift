// EditorHostNSView — the self-contained embeddable editor. It owns the
// InputHostView + GridSurfaceView stack, the native workspace chrome
// (WorkspaceChrome: ChromeKit panels + ShellKit sidebar/tab strip/status
// bar), and an NvimController. Whoever places it in a window gets a fully
// working editor: it attaches its window-bound chrome in
// viewDidMoveToWindow. The host app keeps window construction, menus, and
// app lifecycle (DESIGN.md §10/§14).

import AppKit
import GridKit
import ShellKit
import SurfaceKit

/// Visibility state machine for the pre-session "Connecting to Neovim…"
/// label: visible only when the startup grace period elapses before the
/// first grid content is presented. Pure state so tests can drive it
/// without a timer or a Neovim session.
struct ConnectingIndicatorState {
    private(set) var graceElapsed = false
    private(set) var contentPresented = false

    var isVisible: Bool { graceElapsed && !contentPresented }

    /// The grace timer fired. Returns true when the label should appear
    /// (no content has arrived yet).
    mutating func noteGraceElapsed() -> Bool {
        graceElapsed = true
        return isVisible
    }

    /// First real grid content was presented. Returns true when a visible
    /// label must hide; the label never appears again afterwards.
    mutating func noteContentPresented() -> Bool {
        let wasVisible = isVisible
        contentPresented = true
        return wasVisible
    }
}

@MainActor
public final class EditorHostNSView: NSView {
    /// Below this host width at bridge bootstrap, the runtime defaults the
    /// sidebar and minimap to hidden (startup-time only; explicit
    /// g:superlemon_native_* settings and later toggles are unaffected).
    public static let compactStartupWidthThreshold: CGFloat = 800

    public let controller: NvimController
    public let chrome: WorkspaceChrome

    let surface: GridSurfaceView
    let inputHost: InputHostView
    private var appearanceObservation: NSKeyValueObservation?
    private weak var attachedWindow: NSWindow?
    /// Pre-session affordance over the (opaque) editor surface while a slow
    /// transport starts up. Grace-gated so fast local launches never — or
    /// only fleetingly — show it; hidden permanently on the first flush.
    private let connectingLabel = NSTextField(
        labelWithString: "Connecting to Neovim…")
    private var connectingState = ConnectingIndicatorState()
    private var connectingGraceTask: Task<Void, Never>?

    public init(
        controller: NvimController = NvimController(),
        projectRoot: URL = NvimController.workingDirectory(),
        frame frameRect: NSRect = NSRect(x: 0, y: 0, width: 1160, height: 720)
    ) {
        self.controller = controller
        // A remote-filesystem session sources the sidebar tree and quick-open
        // index through the RPC channel (superlemon.workspace); the local
        // FileManager/FSEvents fast path stays the default. One source
        // instance serves both roles and survives session relaunches.
        let fileAccess: WorkspaceFileAccess
        if controller.hasRemoteFilesystem {
            let source = NvimWorkspaceFileSource(controller: controller)
            fileAccess = WorkspaceFileAccess(
                lister: source, indexSource: source, transport: source, isLocal: false)
        } else {
            fileAccess = .local
        }
        let chrome = WorkspaceChrome(
            controller: controller, projectRoot: projectRoot, fileAccess: fileAccess)
        self.chrome = chrome

        // FontSpec default (nil name → system mono 13pt) until guifont arrives.
        let surface = GridSurfaceView(frame: frameRect, font: FontSpec())
        surface.scrollMotionStyle =
            ScrollPreferences.loadSmoothScrolling() ? .tightNative : .immediate
        self.surface = surface
        let inputHost = InputHostView(
            frame: frameRect, surface: surface, controller: controller)
        self.inputHost = inputHost

        super.init(frame: frameRect)

        controller.chrome = chrome

        // Surface-mode navbar (docs/design/surface-navbar-v1.md §3/§7):
        // the tree is a vim window overlaid inside the editor area.
        do {
            let host = chrome.surfaceHost
            host.mountOverlay = { [weak inputHost] view in
                inputHost?.setSurfaceOverlay(view)
            }
            host.unmountOverlay = { [weak inputHost] _ in
                inputHost?.setSurfaceOverlay(nil)
            }
            host.overlayFrame = { [weak surface, weak inputHost] gridID in
                guard let surface, let inputHost,
                    let gridRect = surface.rect(ofGrid: gridID)
                else { return nil }
                var rect = inputHost.convert(gridRect, from: surface)
                // Cell rounding leaves sub-cell slivers of grid background
                // at the container edges; the navbar reads as a full-height
                // panel, so snap its frame to the left and bottom edges
                // when it already reaches within a cell of them (the
                // hairline border extends with the view).
                let cell = surface.cellSize
                if cell != .zero {
                    if rect.minX < cell.width { rect.origin.x = 0 }
                    let bottom = inputHost.bounds.maxY
                    if bottom - rect.maxY < cell.height * 1.5 {
                        rect.size.height = bottom - rect.origin.y
                    }
                }
                return rect
            }
            host.setOverlaidWindowHandles = { [weak surface] handles in
                surface?.setOverlaidWindowHandles(handles)
            }
            host.cellWidth = { [weak surface] in
                surface?.cellSize.width ?? 0
            }
            host.setWindowCursor = { [weak controller] win, line0 in
                controller?.setSurfaceWindowCursor(win: win, line0: line0)
            }
            host.setWindowWidth = { [weak controller] win, cols in
                controller?.setSurfaceWindowWidth(win: win, cols: cols)
            }
        }

        // Layout: [ editor ] between a tab strip above and a full-width
        // 24pt status bar below. The navbar is a vim window overlaid
        // INSIDE the editor area, so there is no sidebar pane.
        // Native chrome bands (tab strip above, status bar below) start
        // collapsed; nvim's `superlemon.chrome` state opens them (§14).
        let statusBar = chrome.statusBar
        let tabStrip = chrome.tabStrip
        for view in [tabStrip, inputHost, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        let statusBarHeight = statusBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabStripHeight,
            inputHost.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            inputHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: inputHost.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBarHeight,
        ])
        chrome.onChromeModeChange = {
            [weak self, weak controller]
            nativeTabs, nativeStatusbar, nativeMinimap, nativeScrollbars,
            _ in
            tabStripHeight.constant = nativeTabs ? BufferTabStripView.stripHeight : 0
            statusBarHeight.constant = nativeStatusbar ? StatusBarView.barHeight : 0
            // isHidden alongside the collapse: a 0-height NSView still draws
            // its (unclipped) subviews and hit-tests otherwise.
            tabStrip.isHidden = !nativeTabs
            statusBar.isHidden = !nativeStatusbar
            self?.layoutSubtreeIfNeeded()
            controller?.setEditorAccessories(
                minimap: nativeMinimap, scrollbars: nativeScrollbars)
            // The grid gains/loses rows with the bands; don't wait for the
            // next natural layout pass to tell nvim.
            controller?.surfaceLayoutChanged()
        }

        controller.surface = surface
        controller.inputHost = inputHost
        controller.startupLayoutIsCompact = { [weak self] in
            (self?.bounds.width ?? frameRect.width)
                < Self.compactStartupWidthThreshold
        }

        // The surface now paints an opaque background from its very first
        // frame; this label tells the user why the editor area is empty
        // while a slow transport (e.g. an ssh bridge) starts up.
        connectingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        connectingLabel.textColor = .secondaryLabelColor
        // Its backdrop is the surface's fixed pre-colorscheme background
        // (dark), not the window's chrome, so resolve the dynamic color
        // against the dark appearance regardless of the host's theme.
        // (Per-view only; window-appearance ownership is untouched.)
        connectingLabel.appearance = NSAppearance(named: .darkAqua)
        connectingLabel.isHidden = true
        connectingLabel.translatesAutoresizingMaskIntoConstraints = false
        inputHost.addSubview(connectingLabel)
        NSLayoutConstraint.activate([
            connectingLabel.centerXAnchor.constraint(equalTo: inputHost.centerXAnchor),
            connectingLabel.centerYAnchor.constraint(equalTo: inputHost.centerYAnchor),
        ])
        surface.onFirstPresent = { [weak self] in
            self?.noteFirstGridContent()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("EditorHostNSView does not support NSCoding")
    }

    // MARK: - Window attachment

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== attachedWindow else { return }
        attachedWindow = window
        attach(to: window)
        startConnectingGraceIfNeeded()
    }

    /// One grace period per view, clocked from the first window attachment
    /// (when the editor actually becomes visible).
    private func startConnectingGraceIfNeeded() {
        guard connectingGraceTask == nil, !connectingState.graceElapsed,
            !connectingState.contentPresented
        else { return }
        connectingGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            self.connectingGraceTask = nil
            if self.connectingState.noteGraceElapsed() {
                self.connectingLabel.isHidden = false
            }
        }
    }

    private func noteFirstGridContent() {
        connectingGraceTask?.cancel()
        connectingGraceTask = nil
        _ = connectingState.noteContentPresented()
        connectingLabel.isHidden = true
    }

    private func attach(to window: NSWindow) {
        let inputHost = self.inputHost
        controller.window = window
        chrome.attach(window: window, surface: surface)
        chrome.restoreFocus = { [weak window, weak inputHost] in
            window?.makeFirstResponder(inputHost)
        }

        // `.initial` styles the chrome for the appearance the window opens
        // with; without it the first styling only happened on the first
        // appearance *change*, leaving a dark-system launch light-themed.
        appearanceObservation = window.observe(
            \.effectiveAppearance, options: [.initial]
        ) {
            [weak chrome, weak window] _, _ in
            Task { @MainActor in
                guard let window, let chrome else { return }
                let dark =
                    window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                chrome.applyAppearance(dark: dark)
            }
        }
    }

    // MARK: - Host affordances

    /// Gives the editor key focus (the input host becomes first responder).
    public func focusEditor() {
        window?.makeFirstResponder(inputHost)
    }

    /// View ▸ Toggle Sidebar — routed through nvim: the runtime plugin owns
    /// the navbar window (docs/design/surface-navbar-v1.md §3).
    public func toggleSidebar() {
        controller.toggleNativeChrome("sidebar")
    }

    /// View ▸ Smooth Scrolling: display-linked scroll motion (on) vs.
    /// presenting every authoritative Neovim frame as-is (off). The host
    /// app persists the choice through `ScrollPreferences`.
    public func setSmoothScrollingEnabled(_ enabled: Bool) {
        surface.scrollMotionStyle = enabled ? .tightNative : .immediate
    }

    /// Temporary native font-size override (the ⌘= zoom path); nil returns
    /// to the guifont/linespace values from the active Neovim configuration.
    public func setFontSizeOverride(_ size: CGFloat?) {
        controller.overrideFontSize(size)
    }

    /// Persistent host font override (an embedding host's Settings): face
    /// and/or size applied over Neovim's guifont at every font recompute.
    /// nil fields defer to Neovim.
    public func setHostFontOverride(name: String?, size: CGFloat?) {
        controller.setHostFontOverride(name: name, size: size)
    }
}
