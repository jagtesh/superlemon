// AppDelegate — window/chrome layout and the app-level quit flow (DESIGN.md
// §10/§14, NORTHSTAR: flat opaque chrome, three-pane layout — sidebar,
// editor grid, 24pt status bar; light/dark follows nvim's default background
// via NvimController).

import AppKit
import GridKit
import ShellKit
import SurfaceKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    NSMenuItemValidation
{
    private let smokeMode: Bool
    private var controller: NvimController?
    private var chrome: WorkspaceChrome?
    private var window: NSWindow?
    private var sidebarPane: NSView?
    private var appearanceObservation: NSKeyValueObservation?
    private var settings: SettingsWindowController?

    @objc private func showSettings(_ sender: Any?) {
        guard let controller else { return }
        if settings == nil {
            let settings = SettingsWindowController()
            settings.onEditSuperlemonConfig = { [weak controller] in
                if let managed = NvimController.runtimeDirectory()?
                    .appendingPathComponent("config/superlemon.vim")
                {
                    controller?.openSuperlemonConfig(templatePath: managed.path)
                }
            }
            settings.onRelaunch = { [weak self] in self?.relaunch() }
            self.settings = settings
        }
        settings?.show()
    }

    init(smokeMode: Bool) {
        self.smokeMode = smokeMode
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let controller = NvimController()
        self.controller = controller

        if smokeMode {
            configureSmokeMode(controller)
        } else {
            makeWindow(for: controller)
        }

        Task { await controller.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        return controller.handleTerminationRequest()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - NSWindowDelegate

    /// Window close routes through the same `:confirm qa` quit flow as ⌘Q;
    /// the window actually closes when nvim exits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let controller, !controller.sessionExited else { return true }
        // Defer out of the delegate callback before starting app termination.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return false
    }

    // MARK: - Window construction (NORTHSTAR three-pane layout)

    private func makeWindow(for controller: NvimController) {
        let contentRect = NSRect(x: 0, y: 0, width: 1160, height: 720)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Superlemon"
        window.minSize = NSSize(width: 500, height: 320)
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .disallowed
        window.delegate = self

        let projectRoot = NvimController.workingDirectory()
        let chrome = WorkspaceChrome(controller: controller, projectRoot: projectRoot)
        self.chrome = chrome
        controller.chrome = chrome

        // FontSpec default (nil name → system mono 13pt) until guifont arrives.
        let surface = GridSurfaceView(frame: contentRect, font: FontSpec())
        let host = InputHostView(frame: contentRect, surface: surface, controller: controller)

        // Layout: [ sidebar | editor ] over a full-width 24pt status bar.
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(chrome.sidebar)
        splitView.addArrangedSubview(host)
        splitView.setHoldingPriority(.init(300), forSubviewAt: 0)
        splitView.setHoldingPriority(.init(250), forSubviewAt: 1)
        chrome.sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        sidebarPane = chrome.sidebar

        // Native chrome bands (tab strip above, status bar below) start
        // collapsed; nvim's `superlemon.chrome` state opens them (§14).
        let root = NSView()
        let statusBar = chrome.statusBar
        let tabStrip = chrome.tabStrip
        for view in [tabStrip, splitView, statusBar] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let tabStripHeight = tabStrip.heightAnchor.constraint(equalToConstant: 0)
        let statusBarHeight = statusBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tabStrip.topAnchor.constraint(equalTo: root.topAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabStripHeight,
            splitView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBarHeight,
        ])
        chrome.onChromeModeChange = { [weak root, weak controller] nativeTabs, nativeStatusbar in
            tabStripHeight.constant = nativeTabs ? BufferTabStripView.stripHeight : 0
            statusBarHeight.constant = nativeStatusbar ? StatusBarView.barHeight : 0
            // isHidden alongside the collapse: a 0-height NSView still draws
            // its (unclipped) subviews and hit-tests otherwise.
            tabStrip.isHidden = !nativeTabs
            statusBar.isHidden = !nativeStatusbar
            root?.layoutSubtreeIfNeeded()
            // The grid gains/loses rows with the bands; don't wait for the
            // next natural layout pass to tell nvim.
            controller?.surfaceLayoutChanged()
        }
        window.contentView = root

        controller.window = window
        controller.surface = surface
        chrome.attach(window: window, surface: surface)
        chrome.restoreFocus = { [weak window, weak host] in
            window?.makeFirstResponder(host)
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

        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(host)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    // MARK: - Menu actions

    @objc private func presentQuickOpen(_ sender: Any?) {
        chrome?.presentQuickOpen()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        guard let sidebarPane else { return }
        sidebarPane.isHidden.toggle()
    }

    /// View ▸ Native Tabs / Native Status Bar — affordances only; the runtime
    /// plugin owns the state and answers with a superlemon.chrome push.
    @objc private func showMessageHistory(_ sender: Any?) {
        chrome?.toasts.showHistory()
    }

    @objc private func toggleNativeTabs(_ sender: Any?) {
        controller?.toggleNativeChrome("tabs")
    }

    @objc private func toggleNativeStatusBar(_ sender: Any?) {
        controller?.toggleNativeChrome("statusbar")
    }

    /// App menu ▸ Use Superlemon Config: launch nvim with the managed,
    /// native-first init instead of the user's own (takes effect at launch).
    @objc private func toggleManagedConfig(_ sender: Any?) {
        let defaults = UserDefaults.standard
        let key = NvimController.managedConfigDefaultsKey
        defaults.set(!defaults.bool(forKey: key), forKey: key)

        let alert = NSAlert()
        alert.messageText =
            defaults.bool(forKey: key)
            ? "Superlemon will use its built-in configuration"
            : "Superlemon will use your own Neovim configuration (init.vim/init.lua)"
        alert.informativeText = "The change applies when Superlemon relaunches."
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    private func relaunch() {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        // Give the current instance a moment to run its quit flow.
        process.arguments = []
        let path = process.executableURL!.path
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "sleep 0.8; exec \"\(path)\""]
        try? relauncher.run()
        NSApp.terminate(nil)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleNativeTabs(_:)):
            menuItem.state = (chrome?.nativeTabs ?? false) ? .on : .off
        case #selector(toggleNativeStatusBar(_:)):
            menuItem.state = (chrome?.nativeStatusbar ?? false) ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - Smoke mode (--smoke)

    /// Headless verification path: session → store, no window/surface needed
    /// (no WindowServer dependency). Prints "SMOKE OK: <rows>x<cols>
    /// title=<title>" after the first flush, then quits via the quit flow.
    private func configureSmokeMode(_ controller: NvimController) {
        controller.onFirstFlush = { [weak controller] flush in
            let grid = flush.grids[1]
            print("SMOKE OK: \(grid?.rows ?? 0)x\(grid?.cols ?? 0) title=\(flush.title)")
            fflush(stdout)
            controller?.requestQuit()
        }
        controller.exitHandler = { code, stderrTail in
            if code != 0 {
                FileHandle.standardError.write(
                    Data("SMOKE FAIL: nvim exited \(code)\n\(stderrTail)\n".utf8))
            }
            exit(code == 0 ? 0 : 1)
        }
        controller.startupFailureHandler = { message in
            FileHandle.standardError.write(Data("SMOKE FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Menu

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu: About / Quit (⌘Q goes through applicationShouldTerminate).
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            NSMenuItem(
                title: "About Superlemon",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""))
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Superlemon",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        // File menu: Close routed like ⌘Q (via windowShouldClose).
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(
            NSMenuItem(
                title: "Close",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"))

        // Edit menu: Paste → nvim_paste (first responder: InputHostView).
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(
            NSMenuItem(
                title: "Paste",
                action: NSSelectorFromString("paste:"),
                keyEquivalent: "v"))

        // View menu: sidebar toggle.
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "b")
        toggleSidebarItem.target = self
        viewMenu.addItem(toggleSidebarItem)
        viewMenu.addItem(.separator())
        let nativeTabsItem = NSMenuItem(
            title: "Native Tabs",
            action: #selector(toggleNativeTabs(_:)),
            keyEquivalent: "")
        nativeTabsItem.target = self
        viewMenu.addItem(nativeTabsItem)
        let nativeBarItem = NSMenuItem(
            title: "Native Status Bar",
            action: #selector(toggleNativeStatusBar(_:)),
            keyEquivalent: "")
        nativeBarItem.target = self
        viewMenu.addItem(nativeBarItem)
        viewMenu.addItem(.separator())
        let historyItem = NSMenuItem(
            title: "Message History…",
            action: #selector(showMessageHistory(_:)),
            keyEquivalent: "")
        historyItem.target = self
        viewMenu.addItem(historyItem)

        // Go menu: quick-open (⌘P intercepts before key translation — menu
        // key equivalents fire ahead of keyDown, so nvim never sees <D-p>).
        let goItem = NSMenuItem()
        mainMenu.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goItem.submenu = goMenu
        let quickOpenItem = NSMenuItem(
            title: "Quick Open…",
            action: #selector(presentQuickOpen(_:)),
            keyEquivalent: "p")
        quickOpenItem.target = self
        goMenu.addItem(quickOpenItem)

        return mainMenu
    }
}
