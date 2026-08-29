// File ▸ Open Remote Folder… — connect to a host from ~/.ssh/config and open
// its filesystem in a new editor window. The ssh flow is borrowed from
// lemon-tmux: an interactive pty channel authenticates a persisted
// ControlMaster, then the editor rides a `nvim --embed` channel over it.

import AppKit
import EditorHostKit
import NvimKit
import SSHKit

/// The connect / auth flow as a plain AppKit sheet.
///
/// Deliberately static AppKit: during ssh auth the preamble streams a chunk
/// at a time, and rebuilding controls per update loses typed input (a crash
/// class lemon-tmux hit with declarative UI). Here the log view appends text
/// and nothing else moves.
@MainActor
final class ConnectSheetController: NSWindowController {
    var onConnect: ((String) -> Void)?
    var onSendAuth: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let stack = NSStackView()
    private let hostCombo = NSComboBox()
    private let connectButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let logScroll = NSScrollView()
    private let logView = NSTextView()
    private let authField = NSSecureTextField(string: "")
    private let authRow: NSStackView

    init(hosts: [String]) {
        authRow = NSStackView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        super.init(window: window)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        stack.addArrangedSubview(
            NSTextField(labelWithString: "Open a folder on a remote host over SSH."))

        // One editable combo box: ssh_config aliases are the dropdown, typing
        // filters/completes them, and a free-form user@host still works.
        hostCombo.usesDataSource = false
        hostCombo.addItems(withObjectValues: hosts)
        hostCombo.completes = true
        hostCombo.numberOfVisibleItems = 12
        hostCombo.placeholderString = "user@host"
        hostCombo.translatesAutoresizingMaskIntoConstraints = false
        hostCombo.widthAnchor.constraint(equalToConstant: 320).isActive = true
        hostCombo.target = self
        hostCombo.action = #selector(connect(_:))
        connectButton.title = "Connect"
        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connect(_:))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let hostRow = NSStackView(views: [hostCombo, connectButton, cancel])
        hostRow.orientation = .horizontal
        hostRow.spacing = 8
        stack.addArrangedSubview(hostRow)

        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)

        // Auth transcript (banners, MOTD, prompts): appears once connecting.
        logView.isEditable = false
        logView.drawsBackground = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logScroll.hasVerticalScroller = true
        logScroll.drawsBackground = false
        logScroll.borderType = .bezelBorder
        logScroll.documentView = logView
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logScroll.heightAnchor.constraint(equalToConstant: 220),
            logScroll.widthAnchor.constraint(equalToConstant: 480),
        ])
        logView.autoresizingMask = [.width]
        logView.frame = NSRect(x: 0, y: 0, width: 480, height: 220)
        logScroll.isHidden = true
        stack.addArrangedSubview(logScroll)

        authField.placeholderString = "response (password / yes)"
        authField.translatesAutoresizingMaskIntoConstraints = false
        authField.widthAnchor.constraint(equalToConstant: 320).isActive = true
        authField.target = self
        authField.action = #selector(sendAuth(_:))
        let send = NSButton(title: "Send", target: self, action: #selector(sendAuth(_:)))
        send.bezelStyle = .rounded
        authRow.setViews([authField, send], in: .leading)
        authRow.orientation = .horizontal
        authRow.spacing = 8
        authRow.isHidden = true
        stack.addArrangedSubview(authRow)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func focusHostField() {
        window?.makeFirstResponder(hostCombo)
    }

    /// Connecting phase: freeze the destination, reveal transcript + auth.
    func showConnecting(to destination: String) {
        hostCombo.isEnabled = false
        connectButton.isEnabled = false
        statusLabel.stringValue = "Connecting to \(destination)…"
        statusLabel.textColor = .secondaryLabelColor
        logView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        logScroll.isHidden = false
        authRow.isHidden = false
        window?.makeFirstResponder(authField)
    }

    func showStatus(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
    }

    /// Failure keeps the sheet up with the transcript visible so the error
    /// (host key mismatch, wrong password, no nvim) is actionable; the host
    /// field re-arms for another attempt.
    func showFailed(_ message: String) {
        hostCombo.isEnabled = true
        connectButton.isEnabled = true
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        authRow.isHidden = true
        window?.makeFirstResponder(hostCombo)
    }

    /// Append streamed ssh output. Only the text storage changes — no
    /// control is recreated, so typing stays safe while output streams.
    func appendTranscript(_ text: String) {
        guard !text.isEmpty else { return }
        logView.textStorage?.append(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                ]))
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func connect(_ sender: Any) {
        let destination = hostCombo.stringValue.trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty else { return }
        onConnect?(destination)
    }

    @objc private func sendAuth(_ sender: Any) {
        onSendAuth?(authField.stringValue)
        authField.stringValue = ""
    }

    @objc private func cancel(_ sender: Any) {
        onCancel?()
    }
}

/// One connected remote workspace: the persisted ssh master, the
/// `nvim --embed` controller riding it, and the editor window.
@MainActor
final class RemoteHostSession: NSObject, NSWindowDelegate {
    let destination: String
    private let master: SSHMaster
    private let masterRegistry: RemoteMasterRegistry
    let controller: NvimController
    private var editorHost: EditorHostNSView?
    private(set) var window: NSWindow?
    var onClosed: ((RemoteHostSession) -> Void)?

    /// Set only while an app-wide termination is inspecting this session
    /// (see `resolveTermination()`); resolved `true` by the exit that
    /// follows a confirmed quit (`exitHandler`) or `false` by a decline
    /// (`controller.replyToApplicationTermination`, redirected below).
    private var terminationWaiter: ((Bool) -> Void)?

    init(
        destination: String, master: SSHMaster, controller: NvimController,
        masterRegistry: RemoteMasterRegistry
    ) {
        self.destination = destination
        self.master = master
        self.controller = controller
        self.masterRegistry = masterRegistry
        super.init()
        masterRegistry.retain(destination, master: master)
    }

    var sessionController: NvimController { controller }
    var host: EditorHostNSView? { editorHost }

    func openWindow() {
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
        window.title = "\(destination) — Superlemon"
        window.minSize = NSSize(width: 500, height: 320)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.delegate = self

        // "/" as the placeholder root: it exists on any remote host, and the
        // controller re-roots the chrome to the session's real cwd right
        // after the handshake (adoptSessionWorkingDirectory).
        let editorHost = EditorHostNSView(
            controller: controller,
            projectRoot: URL(fileURLWithPath: "/"),
            frame: contentRect)
        self.editorHost = editorHost
        window.contentView = editorHost

        window.center()
        window.makeKeyAndOrderFront(nil)
        editorHost.focusEditor()

        self.window = window

        // Remote nvim exiting (`:q`, connection drop, a confirmed app-wide
        // quit) closes the window. `terminationWaiter` is how
        // `resolveTermination()` learns a pending app-quit's inspection of
        // this session actually finished.
        controller.exitHandler = { [weak self] _, _ in
            Task { @MainActor in
                self?.terminationWaiter?(true)
                self?.terminationWaiter = nil
                self?.finishAndClose()
            }
        }
        // A startup failure's "Quit" button must close only this window,
        // never the whole app (Bug 4: it otherwise falls back to the
        // NvimController default of NSApp.terminate(nil)).
        controller.requestApplicationTermination = { [weak self] in
            self?.finishAndClose()
        }
        // A decline on this session's own quit-inspection dialog
        // (`cancelQuit()` inside NvimController) resolves a pending
        // `.terminateLater` by calling this closure with `false` — redirect
        // it here so `resolveTermination()`'s `await` actually resumes
        // instead of the app-wide termination's `false` reaching
        // `NSApp` on its own, invisibly to AppDelegate's coordinator.
        controller.replyToApplicationTermination = { [weak self] approved in
            self?.terminationWaiter?(approved)
            self?.terminationWaiter = nil
        }

        Task { await controller.start() }
    }

    /// Called by AppDelegate's termination coordinator while ⌘Q/⌘Q-equivalent
    /// is deciding whether the app may quit: runs this session's own
    /// modified-buffer quit inspection (a native dialog on this window, same
    /// machinery `windowShouldClose` uses) and reports whether it cleared.
    /// A confirmed quit resolves `true` through `exitHandler`; a decline
    /// resolves `false` through the redirected `replyToApplicationTermination`
    /// set in `openWindow()`.
    func resolveTermination() async -> Bool {
        switch controller.handleTerminationRequest() {
        case .terminateNow: return true
        case .terminateCancel: return false
        case .terminateLater:
            return await withCheckedContinuation { continuation in
                terminationWaiter = { resolved in continuation.resume(returning: resolved) }
            }
        @unknown default: return true
        }
    }

    /// Close routes through nvim's modified-buffer quit flow, mirroring the
    /// main window: the window actually closes when the remote nvim exits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !controller.sessionExited else {
            teardown()
            return true
        }
        controller.requestQuit()
        return false
    }

    private func finishAndClose() {
        teardown()
        window?.delegate = nil
        window?.close()
    }

    /// Releases this session's hold on the shared ControlMaster rather than
    /// exiting it directly — another window on the same destination may
    /// still be riding it (see `RemoteMasterRegistry`, Bug 3).
    func teardown() {
        controller.stop()
        onClosed?(self)
        let destination = destination
        let masterRegistry = masterRegistry
        Task { await masterRegistry.release(destination) }
    }
}

/// Drives one connect attempt: pty auth to the ready marker, runtime deploy,
/// remote nvim probe, then hands a ready (master, controller) pair back.
@MainActor
final class RemoteConnector {
    enum Outcome {
        case connected(SSHMaster, NvimController)
        case failed(String)
    }

    private var master: SSHMaster?
    private var transcript = ""
    private var markerSeen = false
    private var finished = false
    var onTranscript: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onOutcome: ((Outcome) -> Void)?

    func connect(to destination: String) {
        let master = SSHMaster(endpoint: SSHEndpoint(destination: destination))
        self.master = master
        Task {
            do {
                try await master.connect(
                    onOutput: { [weak self] bytes in
                        let text = String(decoding: bytes, as: UTF8.self)
                        Task { @MainActor in self?.handleOutput(text) }
                    },
                    onExit: { [weak self] status in
                        Task { @MainActor in self?.handleExit(status) }
                    })
            } catch {
                finish(.failed("Could not start ssh: \(error)"))
            }
        }
    }

    func sendAuth(_ response: String) {
        guard let master else { return }
        Task { try? await master.write([UInt8]((response + "\n").utf8)) }
    }

    /// Cancelling a connection attempt must never run `ssh -O exit`: if the
    /// master already reached the ready marker (persisted), another window
    /// dialing the same destination concurrently could be relying on it —
    /// and even if not, `RemoteHostSession` never got a chance to register
    /// it, so this is the only reference to it. Only the local auth pty is
    /// torn down; a lone abandoned master is left for `ControlPersist`'s
    /// idle timeout (Bug 3/7).
    func cancel() {
        finished = true
        guard let master else { return }
        Task { await master.abortAuth() }
    }

    private func handleOutput(_ text: String) {
        transcript += text
        // The marker is plumbing, not something the user typed or the host
        // said — keep it (and its echo artifacts) out of the visible log.
        let visible = text.replacingOccurrences(
            of: SSHCommandBuilder.readyMarker, with: "")
        onTranscript?(visible)
        if !markerSeen, transcript.contains(SSHCommandBuilder.readyMarker) {
            markerSeen = true
            establishSession()
        }
    }

    private func handleExit(_ status: Int32) {
        guard !markerSeen, !finished else { return }
        let tail = transcript.suffix(400)
        finish(
            .failed(
                "ssh exited (\(status)) before authenticating."
                    + (tail.isEmpty ? "" : " Last output:\n\(tail)")))
    }

    /// Auth done, master persisted: deploy the runtime, verify nvim, build
    /// the embed controller.
    private func establishSession() {
        guard let master else { return }
        onStatus?("Connected. Preparing remote host…")
        Task {
            guard await master.check() else {
                finish(.failed("ssh master vanished after authentication."))
                return
            }
            let probe = (try? await master.runRemoteCapturing(
                ["command -v nvim || echo __SUPERLEMON_NO_NVIM__"])) ?? ""
            if probe.isEmpty || probe.contains("__SUPERLEMON_NO_NVIM__") {
                finish(.failed(
                    "nvim was not found on the remote host. "
                        + "Install Neovim there and try again."))
                return
            }
            onStatus?("Deploying editor runtime…")
            guard let runtime = NvimController.runtimeDirectory() else {
                finish(.failed("Local superlemon runtime directory is missing."))
                return
            }
            do {
                try await master.deployDirectory(
                    localPath: runtime.path,
                    remotePath: SSHCommandBuilder.remoteRuntimeDirectory)
            } catch {
                finish(.failed("Runtime deploy failed: \(error)"))
                return
            }

            // The remote session honors the same Settings choice as local
            // launch: managed (default) and custom load the deployed init
            // via -u, "My Neovim configuration" uses the remote host's own.
            let selection = NvimConfigPreferences.loadAndMigrate()
            let remoteConfig: RemoteNvimConfig
            switch selection.mode {
            case .managed:
                remoteConfig = .editorManaged
            case .user:
                remoteConfig = .remoteUser
            case .custom:
                guard let path = selection.customInitPath,
                    let contents = FileManager.default.contents(atPath: path)
                else {
                    finish(.failed(
                        "The custom init file could not be read: "
                            + (selection.customInitPath ?? "no file chosen")))
                    return
                }
                do {
                    try await master.deployCustomInit(contents)
                } catch {
                    finish(.failed("Custom init deploy failed: \(error)"))
                    return
                }
                remoteConfig = .customInit(
                    remotePath: SSHCommandBuilder.remoteCustomInitPath)
            }

            // The far side's config mode decides startup validation: only a
            // Superlemon-selected custom init is diagnosed; the remote user's
            // own init is trusted like a local `.user` launch. "Start Safely"
            // relaunches on the deployed managed baseline, as it does locally.
            let configMode: NvimConfigMode
            switch remoteConfig {
            case .editorManaged: configMode = .managed
            case .remoteUser: configMode = .user
            case .customInit: configMode = .custom
            }
            let sshBinary = URL(fileURLWithPath: master.sshExecutablePath)
            let controller = NvimController(
                launchConfiguration: NvimLaunchConfiguration(
                    binaryURL: sshBinary,
                    arguments: await master.embeddedNvimArguments(config: remoteConfig)),
                configMode: configMode,
                safeStartConfiguration: NvimLaunchConfiguration(
                    binaryURL: sshBinary,
                    arguments: await master.embeddedNvimArguments(config: .editorManaged)))
            finish(.connected(master, controller))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        onOutcome?(outcome)
    }
}
