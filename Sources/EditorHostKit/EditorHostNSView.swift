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
    private let splitView = NSSplitView()
    private var appearanceObservation: NSKeyValueObservation?
    private weak var attachedWindow: NSWindow?
    /// Last sidebar visibility applied from a `superlemon.chrome` push.
    /// Pushes resend the whole map, so only a changed value reaches the
    /// split view — direct setSidebarVisible calls from embedding hosts
    /// survive unrelated chrome pushes.
    private var lastAppliedNativeSidebar: Bool?

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
        self.surface = surface
        let inputHost = InputHostView(
            frame: frameRect, surface: surface, controller: controller)
        self.inputHost = inputHost

        super.init(frame: frameRect)

        controller.chrome = chrome

        // Layout: [ sidebar | editor ] over a full-width 24pt status bar.
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(chrome.sidebar)
        splitView.addArrangedSubview(inputHost)
        splitView.setHoldingPriority(.init(300), forSubviewAt: 0)
        splitView.setHoldingPriority(.init(250), forSubviewAt: 1)
        chrome.sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        // Native chrome bands (tab strip above, status bar below) start
        // collapsed; nvim's `superlemon.chrome` state opens them (§14).
        let statusBar = chrome.statusBar
        let tabStrip = chrome.tabStrip
        for view in [tabStrip, splitView, statusBar] {
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
            splitView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBarHeight,
        ])
        chrome.onChromeModeChange = {
            [weak self, weak controller]
            nativeTabs, nativeStatusbar, nativeMinimap, nativeScrollbars,
            nativeSidebar in
            tabStripHeight.constant = nativeTabs ? BufferTabStripView.stripHeight : 0
            statusBarHeight.constant = nativeStatusbar ? StatusBarView.barHeight : 0
            // isHidden alongside the collapse: a 0-height NSView still draws
            // its (unclipped) subviews and hit-tests otherwise.
            tabStrip.isHidden = !nativeTabs
            statusBar.isHidden = !nativeStatusbar
            if let self, nativeSidebar != self.lastAppliedNativeSidebar {
                self.lastAppliedNativeSidebar = nativeSidebar
                self.setSidebarVisible(nativeSidebar)
            }
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
    }

    private func attach(to window: NSWindow) {
        let inputHost = self.inputHost
        controller.window = window
        chrome.attach(window: window, surface: surface)
        chrome.restoreFocus = { [weak window, weak inputHost] in
            window?.makeFirstResponder(inputHost)
        }

        // Sidebar starts at a fraction of the NORTHSTAR 370pt design width,
        // proportional to our default window.
        window.layoutIfNeeded()
        splitView.setPosition(260, ofDividerAt: 0)

        appearanceObservation = window.observe(\.effectiveAppearance) {
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

    /// View ▸ Toggle Sidebar.
    public func toggleSidebar() {
        chrome.sidebar.isHidden.toggle()
    }

    /// Show or hide the project sidebar. Remote-filesystem sessions
    /// (`NvimController.hasRemoteFilesystem`) now source the tree and
    /// quick-open index through the session's RPC channel, so embedding
    /// hosts no longer need to hide the sidebar for correctness — this
    /// remains a purely presentational choice.
    public func setSidebarVisible(_ visible: Bool) {
        chrome.sidebar.isHidden = !visible
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
