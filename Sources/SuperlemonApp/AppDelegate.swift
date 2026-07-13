// AppDelegate — current window/chrome layout and app-level quit flow
// (DESIGN.md §10/§14). Light/dark follows nvim's default background through
// NvimController.

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
    private var savePanelIsOpen = false
    private var smokeDeadlineTask: Task<Void, Never>?

    @objc private func showSettings(_ sender: Any?) {
        guard let controller else { return }
        if settings == nil {
            let settings = SettingsWindowController()
            settings.onEditConfiguration = { [weak controller] selection in
                if let template = NvimController.runtimeDirectory()?
                    .appendingPathComponent("config/user-init.vim")
                {
                    controller?.openConfiguration(
                        selection,
                        managedTemplatePath: template.path)
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

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - NSWindowDelegate

    /// Window close routes through the same native modified-buffer quit flow
    /// as ⌘Q; the window actually closes when nvim exits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let controller, !controller.sessionExited else { return true }
        // Defer out of the delegate callback before starting app termination.
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return false
    }

    // MARK: - Window construction

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
        chrome.onSaveAsRequested = { [weak self] in self?.presentSaveAs() }

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
        chrome.onChromeModeChange = {
            [weak root, weak controller]
            nativeTabs, nativeStatusbar, nativeMinimap, nativeScrollbars in
            tabStripHeight.constant = nativeTabs ? BufferTabStripView.stripHeight : 0
            statusBarHeight.constant = nativeStatusbar ? StatusBarView.barHeight : 0
            // isHidden alongside the collapse: a 0-height NSView still draws
            // its (unclipped) subviews and hit-tests otherwise.
            tabStrip.isHidden = !nativeTabs
            statusBar.isHidden = !nativeStatusbar
            root?.layoutSubtreeIfNeeded()
            controller?.setEditorAccessories(
                minimap: nativeMinimap, scrollbars: nativeScrollbars)
            // The grid gains/loses rows with the bands; don't wait for the
            // next natural layout pass to tell nvim.
            controller?.surfaceLayoutChanged()
        }
        window.contentView = root

        controller.window = window
        controller.surface = surface
        controller.inputHost = host
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

    @objc private func showAbout(_ sender: Any?) {
        let legalParagraph = NSMutableParagraphStyle()
        legalParagraph.alignment = .center
        legalParagraph.lineSpacing = 1
        legalParagraph.paragraphSpacing = 10

        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.alignment = .center
        bodyParagraph.lineSpacing = 1

        let credits = NSMutableAttributedString(
            string:
                "Copyright © 2026 Jagtesh Chadha\u{2028}"
                + "Licensed under the BSD 3-Clause License\n",
            attributes: [
                .font: NSFont.systemFont(
                    ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: legalParagraph,
            ])
        credits.append(NSAttributedString(
            string:
                "Superlemon stands on the shoulders of giants: Vim, Neovim, and "
                + "Sublime Text—three of my favourite editors. They inspired its "
                + "editing behaviour, feel, and layout, while Neovim’s exceptional "
                + "client–server architecture powers it.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: bodyParagraph,
            ]))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Superlemon",
            .applicationIcon: NSApp.applicationIconImage as Any,
            .credits: credits,
        ])
    }

    @objc private func openFile(_ sender: Any?) {
        guard let controller else { return }
        Task { [weak self, weak controller] in
            guard let self, let controller, let window = self.window else { return }
            let panel = NSOpenPanel()
            panel.title = "Open File"
            panel.prompt = "Open"
            panel.directoryURL = self.chrome?.projectRoot ?? NvimController.workingDirectory()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = true
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return }
            controller.openFile(url.path)
        }
    }

    @objc private func openFolder(_ sender: Any?) {
        guard let controller else { return }
        Task { [weak self, weak controller] in
            guard let self, let controller, let window = self.window else { return }
            let panel = NSOpenPanel()
            panel.title = "Open Folder"
            panel.prompt = "Open"
            panel.directoryURL = self.chrome?.projectRoot ?? NvimController.workingDirectory()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.resolvesAliases = true
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return }
            controller.openFolder(url.path)
        }
    }

    /// File ▸ Save is semantic even when a user remaps <D-s> in Neovim.
    @objc private func saveFile(_ sender: Any?) {
        controller?.saveCurrentBuffer()
    }

    @objc private func saveFileAs(_ sender: Any?) {
        presentSaveAs()
    }

    private func presentSaveAs() {
        guard !savePanelIsOpen, let controller, let window else { return }
        savePanelIsOpen = true
        Task { [weak self, controller, window] in
            guard let self else { return }
            defer { self.savePanelIsOpen = false }
            let currentPath = await controller.currentBufferPath()
            let panel = NSSavePanel()
            panel.title = "Save File As"
            panel.prompt = "Save"
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            if let currentPath {
                let currentURL = URL(fileURLWithPath: currentPath)
                panel.directoryURL = currentURL.deletingLastPathComponent()
                panel.nameFieldStringValue = currentURL.lastPathComponent
            } else {
                panel.directoryURL = self.chrome?.projectRoot ?? NvimController.workingDirectory()
                panel.nameFieldStringValue = "Untitled"
            }
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK, let url = panel.url else { return }
            controller.saveFile(as: url.path)
        }
    }

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

    @objc private func toggleMinimap(_ sender: Any?) {
        controller?.toggleNativeChrome("minimap")
    }

    private func relaunch() {
        controller?.requestRelaunch {
            let process = Process()
            process.executableURL = URL(
                fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            process.arguments = []
            try process.run()
        }
    }

    @objc private func showHelp(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/jagtesh/superlemon") else { return }
        NSWorkspace.shared.open(url)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openFile(_:)), #selector(openFolder(_:)),
            #selector(presentQuickOpen(_:)):
            return controller?.editorCommandsAvailable ?? false
        case #selector(saveFile(_:)):
            return controller?.canSaveCurrentBuffer ?? false
        case #selector(saveFileAs(_:)):
            return (controller?.editorCommandsAvailable ?? false) && !savePanelIsOpen
        case #selector(toggleNativeTabs(_:)):
            menuItem.state = (chrome?.nativeTabs ?? false) ? .on : .off
            return controller?.editorCommandsAvailable ?? false
        case #selector(toggleNativeStatusBar(_:)):
            menuItem.state = (chrome?.nativeStatusbar ?? false) ? .on : .off
            return controller?.editorCommandsAvailable ?? false
        case #selector(toggleMinimap(_:)):
            menuItem.state = (chrome?.nativeMinimap ?? true) ? .on : .off
            return controller?.editorCommandsAvailable ?? false
        default:
            return true
        }
    }

    // MARK: - Smoke mode (--smoke)

    /// Headless verification path: session → store, no window/surface needed
    /// (no WindowServer dependency). Prints "SMOKE OK: <rows>x<cols>
    /// title=<title>" after the first flush, then quits via the quit flow.
    private func configureSmokeMode(_ controller: NvimController) {
        smokeDeadlineTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard self != nil else { return }
            FileHandle.standardError.write(
                Data("SMOKE FAIL: readiness deadline exceeded\n".utf8))
            fflush(stderr)
            exit(1)
        }
        controller.onFirstFlush = { [weak controller] flush in
            let grid = flush.grids[1]
            print("SMOKE OK: \(grid?.rows ?? 0)x\(grid?.cols ?? 0) title=\(flush.title)")
            fflush(stdout)
            controller?.requestQuit()
        }
        controller.exitHandler = { [weak self] code, stderrTail in
            self?.smokeDeadlineTask?.cancel()
            if code != 0 {
                FileHandle.standardError.write(
                    Data("SMOKE FAIL: nvim exited \(code)\n\(stderrTail)\n".utf8))
            }
            exit(code == 0 ? 0 : 1)
        }
        controller.startupFailureHandler = { [weak self] message in
            self?.smokeDeadlineTask?.cancel()
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
        let aboutItem = NSMenuItem(
            title: "About Superlemon",
            action: #selector(showAbout(_:)),
            keyEquivalent: "")
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Hide Superlemon",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(
            NSMenuItem(
                title: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""))
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(
            NSMenuItem(
                title: "Quit Superlemon",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        // File menu: native panels choose paths; Neovim owns all buffer I/O.
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu

        let openFileItem = NSMenuItem(
            title: "Open File…",
            action: #selector(openFile(_:)),
            keyEquivalent: "o")
        openFileItem.target = self
        fileMenu.addItem(openFileItem)

        let openFolderItem = NSMenuItem(
            title: "Open Folder…",
            action: #selector(openFolder(_:)),
            keyEquivalent: "o")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        openFolderItem.target = self
        fileMenu.addItem(openFolderItem)

        fileMenu.addItem(.separator())

        let saveItem = NSMenuItem(
            title: "Save",
            action: #selector(saveFile(_:)),
            keyEquivalent: "s")
        saveItem.target = self
        fileMenu.addItem(saveItem)

        let saveAsItem = NSMenuItem(
            title: "Save As…",
            action: #selector(saveFileAs(_:)),
            keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        saveAsItem.target = self
        fileMenu.addItem(saveAsItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(
            NSMenuItem(
                title: "Close",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"))

        // Standard responder-chain selectors keep native text fields, save
        // panels, and inline rename controls native. InputHostView implements
        // the same selectors semantically for Neovim and validates them from
        // the latest status snapshot.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        let undoItem = NSMenuItem(
            title: "Undo", action: #selector(InputHostView.undo(_:)), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(
            title: "Redo", action: #selector(InputHostView.redo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        let cutItem = NSMenuItem(
            title: "Cut", action: #selector(InputHostView.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(cutItem)
        let copyItem = NSMenuItem(
            title: "Copy", action: #selector(InputHostView.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(copyItem)
        let pasteItem = NSMenuItem(
            title: "Paste", action: #selector(InputHostView.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(pasteItem)
        let selectAllItem = NSMenuItem(
            title: "Select All", action: #selector(InputHostView.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(selectAllItem)
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(
            title: "Find…", action: #selector(InputHostView.performFindPanelAction(_:)),
            keyEquivalent: "f")
        editMenu.addItem(findItem)

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
        let minimapItem = NSMenuItem(
            title: "Minimap",
            action: #selector(toggleMinimap(_:)),
            keyEquivalent: "")
        minimapItem.target = self
        viewMenu.addItem(minimapItem)
        // Native scroll bars are hidden from the menu while the standalone
        // NSScroller presentation is unreliable; the runtime plumbing stays
        // (:SuperlemonChrome scrollbars / g:superlemon_native_scrollbars,
        // both default off).
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

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(
            NSMenuItem(
                title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"))
        windowMenu.addItem(
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            NSMenuItem(
                title: "Bring All to Front",
                action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        let help = NSMenuItem(
            title: "Superlemon Help", action: #selector(showHelp(_:)), keyEquivalent: "?")
        help.target = self
        helpMenu.addItem(help)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }
}
