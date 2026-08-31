// AppDelegate — current window/chrome layout and app-level quit flow
// (DESIGN.md §10/§14). Light/dark follows nvim's default background through
// NvimController.

import AppKit
import EditorHostKit
import GridKit
import SSHKit
import ShellKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
    NSMenuItemValidation
{
    private let smokeMode: Bool
    private var controller: NvimController?
    private var editorHost: EditorHostNSView?
    private var window: NSWindow?
    private var settings: SettingsWindowController?
    private var savePanelIsOpen = false
    private var smokeDeadlineTask: Task<Void, Never>?
    private var remoteSessions: [RemoteHostSession] = []
    private var connectSheet: ConnectSheetController?
    private var connector: RemoteConnector?
    /// Shared across every "Open Remote Folder" session so windows to the
    /// same destination don't each own an independent exit of the
    /// ControlMaster they're all riding (Bug 3).
    private let remoteMasterRegistry = RemoteMasterRegistry()
    /// Bumped on every `applicationShouldTerminate` call; guards the async
    /// remote-consensus coordinator below against acting on a stale
    /// termination attempt the user already cancelled.
    private var terminationGeneration = 0

    // Menu actions target the key window's editor, so a remote window's ⌘S
    // saves the remote buffer, not the local one's.
    private var keyEditorHost: EditorHostNSView? {
        NSApp.keyWindow?.contentView as? EditorHostNSView
    }
    private var activeController: NvimController? { keyEditorHost?.controller ?? controller }
    private var activeEditorWindow: NSWindow? {
        keyEditorHost?.window ?? window
    }

    private var chrome: WorkspaceChrome? { keyEditorHost?.chrome ?? editorHost?.chrome }

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
            settings.onAppearanceModeChanged = { [weak self] in
                self?.controller?.applyAppearancePreference()
                for session in self?.remoteSessions ?? [] {
                    session.controller.applyAppearancePreference()
                }
            }
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

    /// Every remote window may hold unsaved buffers too, and each deserves
    /// its own native modified-buffer dialog before the app actually quits
    /// (Bug 2). Remotes are inspected first, one at a time; only once every
    /// one has cleanly consented does the local controller run its own
    /// self-contained quit flow — the same one this method always ran for
    /// the local-only case, untouched below.
    ///
    /// Each remote session's `resolveTermination()` resolves `true` (via
    /// `exitHandler`, on a confirmed quit) or `false` (via a redirected
    /// `replyToApplicationTermination`, on a decline) — see
    /// `RemoteHostSession.openWindow()`. A decline means `NSApp` was never
    /// told anything by the controller itself (that closure is redirected
    /// here instead of calling the real `NSApp.reply`), so this coordinator
    /// is the one that must reply `false` on its behalf.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller else { return .terminateNow }
        guard !remoteSessions.isEmpty else {
            return controller.handleTerminationRequest()
        }

        terminationGeneration += 1
        let generation = terminationGeneration
        let sessions = remoteSessions
        Task { @MainActor [weak self] in
            guard let self else { return }
            var aggregate = TerminationAggregate(participants: sessions.count)
            for session in sessions {
                let reply = await session.resolveTermination()
                guard self.terminationGeneration == generation else { return }
                if aggregate.add(reply: reply) == .cancelled {
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            guard aggregate.status == .approved, self.terminationGeneration == generation
            else { return }
            guard let controller = self.controller else {
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            // Defensive: clear a leftover one-shot handler from a
            // previously *cancelled* ⌘W-with-remotes-open close (see
            // windowShouldClose) so this real quit isn't swallowed by it.
            controller.exitHandler = nil
            switch controller.handleTerminationRequest() {
            case .terminateNow:
                NSApp.reply(toApplicationShouldTerminate: true)
            case .terminateCancel:
                NSApp.reply(toApplicationShouldTerminate: false)
            case .terminateLater:
                break  // its own default reply closure resolves this.
            @unknown default:
                break
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        for session in remoteSessions { session.controller.stop() }
        // The process is exiting now; there's no time left for the
        // graceful per-session release dance (Task-based, async). Exit
        // every still-registered ControlMaster synchronously instead —
        // the only chance to run `ssh -O exit` before ControlPersist's
        // idle timeout would otherwise be the sole cleanup (Bug 7).
        remoteMasterRegistry.exitAllSynchronously()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - NSWindowDelegate

    /// Window close routes through the same native modified-buffer quit flow
    /// as ⌘Q; the window actually closes when nvim exits.
    ///
    /// With no remote windows open, closing the one local window is
    /// equivalent to quitting — unchanged from before. With remote windows
    /// still open (Bug 2), ⌘W must close only the local window: a one-shot
    /// `exitHandler` takes over from `NvimController`'s default
    /// app-terminating behavior for this exit alone, so the app survives
    /// with its remote windows intact.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let controller, !controller.sessionExited else { return true }
        guard !remoteSessions.isEmpty else {
            // Defer out of the delegate callback before starting app termination.
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        }
        controller.exitHandler = { [weak self, weak controller] _, _ in
            controller?.exitHandler = nil
            self?.window?.delegate = nil
            self?.window?.close()
            self?.window = nil
            self?.editorHost = nil
        }
        controller.requestQuit()
        return false
    }

    // MARK: - Window construction

    private func makeWindow(for controller: NvimController) {
        // Fit small displays instead of overflowing them; a resulting width
        // under EditorHostNSView.compactStartupWidthThreshold starts the
        // sidebar and minimap hidden (unless the user's config sets them).
        let available = NSScreen.main?.visibleFrame.size
            ?? NSSize(width: 1160, height: 720)
        let contentRect = NSRect(
            x: 0, y: 0,
            width: min(1160, available.width),
            height: min(720, available.height))
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

        // The embeddable editor (EditorHostKit) owns the surface/input stack,
        // the native chrome, and the controller wiring; placing it as the
        // content view attaches it to this window.
        let editorHost = EditorHostNSView(
            controller: controller,
            projectRoot: NvimController.workingDirectory(),
            frame: contentRect)
        self.editorHost = editorHost
        editorHost.chrome.onSaveAsRequested = { [weak self] in self?.presentSaveAs() }
        window.contentView = editorHost

        window.center()
        window.makeKeyAndOrderFront(nil)
        editorHost.focusEditor()
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
        guard let controller = activeController else { return }
        Task { [weak self, weak controller] in
            guard let self, let controller, let window = self.activeEditorWindow else { return }
            if controller.hasRemoteFilesystem {
                guard let path = await self.chooseRemotePath(
                    controller: controller, window: window, mode: .openFile, title: "Open File")
                else { return }
                controller.openFile(path)
                return
            }
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
        guard let controller = activeController else { return }
        Task { [weak self, weak controller] in
            guard let self, let controller, let window = self.activeEditorWindow else { return }
            if controller.hasRemoteFilesystem {
                guard let path = await self.chooseRemotePath(
                    controller: controller, window: window, mode: .openDirectory,
                    title: "Open Folder")
                else { return }
                controller.openFolder(path)
                return
            }
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
        activeController?.saveCurrentBuffer()
    }

    @objc private func saveFileAs(_ sender: Any?) {
        presentSaveAs()
    }

    private func presentSaveAs() {
        guard !savePanelIsOpen, let controller = activeController,
            let window = activeEditorWindow
        else { return }
        savePanelIsOpen = true
        Task { [weak self, controller, window] in
            guard let self else { return }
            defer { self.savePanelIsOpen = false }
            let currentPath = await controller.currentBufferPath()
            if controller.hasRemoteFilesystem {
                let defaultName = currentPath.map {
                    URL(fileURLWithPath: $0).lastPathComponent
                } ?? "Untitled"
                guard let path = await self.chooseRemotePath(
                    controller: controller, window: window,
                    mode: .saveFile(defaultName: defaultName), title: "Save File As")
                else { return }
                controller.saveFile(as: path)
                return
            }
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

    /// A remote session's filesystem is unreachable for NSOpenPanel and
    /// NSSavePanel; the same tree the sidebar browses over RPC stands in as
    /// the dialog, rooted at the session's working directory.
    private func chooseRemotePath(
        controller: NvimController, window: NSWindow,
        mode: WorkspaceFilePanelMode, title: String
    ) async -> String? {
        let cwd = await controller.currentWorkingDirectory() ?? "/"
        let panel = WorkspaceFilePanelController(
            lister: NvimWorkspaceFileSource(controller: controller),
            root: URL(fileURLWithPath: cwd, isDirectory: true),
            mode: mode, title: title)
        return await withCheckedContinuation { continuation in
            panel.beginSheet(on: window) { path in
                withExtendedLifetime(panel) { continuation.resume(returning: path) }
            }
        }
    }

    @objc private func presentQuickOpen(_ sender: Any?) {
        chrome?.presentQuickOpen()
    }

    @objc private func toggleSidebar(_ sender: Any?) {
        activeController?.toggleNativeChrome("sidebar")
    }

    /// View ▸ Native Tabs / Native Status Bar — affordances only; the runtime
    /// plugin owns the state and answers with a superlemon.chrome push.
    @objc private func showMessageHistory(_ sender: Any?) {
        chrome?.toasts.showHistory()
    }

    @objc private func toggleNativeTabs(_ sender: Any?) {
        activeController?.toggleNativeChrome("tabs")
    }

    @objc private func toggleNativeStatusBar(_ sender: Any?) {
        activeController?.toggleNativeChrome("statusbar")
    }

    @objc private func toggleMinimap(_ sender: Any?) {
        activeController?.toggleNativeChrome("minimap")
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
            return activeController?.editorCommandsAvailable ?? false
        case #selector(openRemoteFolder(_:)):
            return connectSheet == nil
        case #selector(saveFile(_:)):
            return activeController?.canSaveCurrentBuffer ?? false
        case #selector(saveFileAs(_:)):
            return (activeController?.editorCommandsAvailable ?? false) && !savePanelIsOpen
        case #selector(toggleNativeTabs(_:)):
            menuItem.state = (chrome?.nativeTabs ?? false) ? .on : .off
            return activeController?.editorCommandsAvailable ?? false
        case #selector(toggleNativeStatusBar(_:)):
            menuItem.state = (chrome?.nativeStatusbar ?? false) ? .on : .off
            return activeController?.editorCommandsAvailable ?? false
        case #selector(toggleMinimap(_:)):
            menuItem.state = (chrome?.nativeMinimap ?? true) ? .on : .off
            return activeController?.editorCommandsAvailable ?? false
        case #selector(toggleSidebar(_:)):
            menuItem.state = (chrome?.nativeSidebar ?? true) ? .on : .off
            return activeController?.editorCommandsAvailable ?? false
        case #selector(toggleSmoothScrolling(_:)):
            menuItem.state = ScrollPreferences.loadSmoothScrolling() ? .on : .off
            return true
        default:
            return true
        }
    }

    /// View ▸ Smooth Scrolling: a GUI-side rendering preference, persisted
    /// in UserDefaults (ScrollPreferences) and applied to every open editor
    /// window immediately; new windows pick it up at construction.
    @objc private func toggleSmoothScrolling(_ sender: Any?) {
        let enabled = !ScrollPreferences.loadSmoothScrolling()
        ScrollPreferences.save(smoothScrolling: enabled)
        for window in NSApp.windows {
            (window.contentView as? EditorHostNSView)?
                .setSmoothScrollingEnabled(enabled)
        }
    }

    // MARK: - Remote host (File ▸ Open Remote Folder…)

    /// Sheet on the frontmost editor window: pick/type a destination, watch
    /// the ssh transcript, answer auth prompts. Success opens the remote
    /// filesystem in a new editor window; the local window stays untouched.
    @objc private func openRemoteFolder(_ sender: Any?) {
        guard connectSheet == nil, let hostWindow = activeEditorWindow else { return }
        let sheet = ConnectSheetController(hosts: SSHConfigHosts.listAliases())
        connectSheet = sheet

        sheet.onCancel = { [weak self] in
            self?.connector?.cancel()
            self?.dismissConnectSheet(on: hostWindow)
        }
        sheet.onSendAuth = { [weak self] response in
            self?.connector?.sendAuth(response)
        }
        sheet.onConnect = { [weak self] destination in
            guard let self else { return }
            let connector = RemoteConnector()
            self.connector = connector
            connector.onTranscript = { [weak sheet] text in sheet?.appendTranscript(text) }
            connector.onStatus = { [weak sheet] status in sheet?.showStatus(status) }
            connector.onOutcome = { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .failed(let message):
                    self.connector = nil
                    self.connectSheet?.showFailed(message)
                case .connected(let master, let controller):
                    self.connector = nil
                    self.dismissConnectSheet(on: hostWindow)
                    let session = RemoteHostSession(
                        destination: destination, master: master, controller: controller,
                        masterRegistry: self.remoteMasterRegistry)
                    session.onClosed = { [weak self] closed in
                        guard let self else { return }
                        self.remoteSessions.removeAll { $0 === closed }
                        // The local window may already be closed (Bug 2's
                        // ⌘W-with-remotes-open path leaves the app running
                        // headless-of-local-window until every remote is
                        // done); once the last remote goes too, the app has
                        // nothing left to show and should quit.
                        if self.remoteSessions.isEmpty, self.controller?.sessionExited ?? true {
                            NSApp.terminate(nil)
                        }
                    }
                    self.remoteSessions.append(session)
                    session.openWindow()
                }
            }
            sheet.showConnecting(to: destination)
            connector.connect(to: destination)
        }

        if let sheetWindow = sheet.window {
            hostWindow.beginSheet(sheetWindow)
            sheet.focusHostField()
        }
    }

    private func dismissConnectSheet(on hostWindow: NSWindow) {
        if let sheetWindow = connectSheet?.window {
            hostWindow.endSheet(sheetWindow)
            sheetWindow.orderOut(nil)
        }
        connectSheet = nil
        connector = nil
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

        let openRemoteItem = NSMenuItem(
            title: "Open Remote Folder…",
            action: #selector(openRemoteFolder(_:)),
            keyEquivalent: "o")
        openRemoteItem.keyEquivalentModifierMask = [.command, .option]
        openRemoteItem.target = self
        fileMenu.addItem(openRemoteItem)

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
        let smoothScrollItem = NSMenuItem(
            title: "Smooth Scrolling",
            action: #selector(toggleSmoothScrolling(_:)),
            keyEquivalent: "")
        smoothScrollItem.target = self
        viewMenu.addItem(smoothScrollItem)
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
